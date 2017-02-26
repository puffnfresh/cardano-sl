{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE UndecidableInstances #-}

module Pos.Security.Workers
       ( SecurityWorkersClass (..)
       ) where

import           Control.Concurrent.STM      (TVar, newTVar, readTVar, writeTVar)
import qualified Data.HashMap.Strict         as HM
import           Data.Tagged                 (Tagged (..))
import           Data.Time.Units             (convertUnit)
import           Formatting                  (build, int, sformat, (%))
import           Mockable                    (delay)
import           Paths_cardano_sl            (version)
import           System.Wlog                 (logNotice, logWarning)
import           Universum

import           Pos.Binary.Ssc              ()
import           Pos.Block.Network.Retrieval (requestTipOuts, triggerRecovery)
import           Pos.Communication.Protocol  (OutSpecs, SendActions, WorkerSpec,
                                              localWorker, worker)
import           Pos.Constants               (blkSecurityParam, mdNoBlocksSlotThreshold,
                                              mdNoCommitmentsEpochThreshold)
import           Pos.Context                 (getNodeContext, getUptime, isRecoveryMode,
                                              ncPublicKey)
import           Pos.Crypto                  (PublicKey)
import           Pos.DB                      (DBError (DBMalformed), getBlockHeader,
                                              getTipBlockHeader, loadBlundsFromTipByDepth)
import           Pos.DB.Class                (MonadDB)
import           Pos.Reporting.Methods       (reportMisbehaviourMasked, reportingFatal)
import           Pos.Security.Class          (SecurityWorkersClass (..))
import           Pos.Shutdown                (runIfNotShutdown)
import           Pos.Slotting                (getCurrentSlot, getLastKnownSlotDuration,
                                              onNewSlot)
import           Pos.Ssc.Class.Helpers       (SscHelpersClass)
import           Pos.Ssc.GodTossing          (GtPayload (..), SscGodTossing,
                                              getCommitmentsMap)
import           Pos.Ssc.NistBeacon          (SscNistBeacon)
import           Pos.Types                   (BlockHeader, EpochIndex, MainBlock,
                                              SlotId (..), addressHash, blockMpc,
                                              flattenEpochOrSlot, flattenSlotId,
                                              genesisHash, headerHash, headerLeaderKey,
                                              prevBlockL)
import           Pos.Util                    (mconcatPair)
import           Pos.Util.TimeWarp           (sec)
import           Pos.WorkMode                (WorkMode)


instance SecurityWorkersClass SscGodTossing where
    securityWorkers =
        Tagged $
        merge [checkForReceivedBlocksWorker, checkForIgnoredCommitmentsWorker]
      where
        merge = mconcatPair . map (first pure)

instance SecurityWorkersClass SscNistBeacon where
    securityWorkers = Tagged $ first pure checkForReceivedBlocksWorker

checkForReceivedBlocksWorker :: WorkMode ssc m => (WorkerSpec m, OutSpecs)
checkForReceivedBlocksWorker =
    worker requestTipOuts checkForReceivedBlocksWorkerImpl

checkEclipsed
    :: (SscHelpersClass ssc, MonadDB ssc m)
    => PublicKey -> SlotId -> BlockHeader ssc -> m Bool
checkEclipsed ourPk slotId = notEclipsed
  where
    onBlockLoadFailure header = do
        throwM $ DBMalformed $
            sformat ("Eclipse check: didn't manage to find parent of "%build%
                     " with hash "%build%", which is not genesis")
                    (headerHash header)
                    (header ^. prevBlockL)
    -- We stop looking for blocks when we've gone earlier than
    -- 'mdNoBlocksSlotThreshold':
    pastThreshold header =
        (flattenSlotId slotId - flattenEpochOrSlot header) >
        mdNoBlocksSlotThreshold
    -- Run the iteration starting from tip block; if we have found
    -- that we're eclipsed, we report it and ask neighbors for
    -- headers. If there are no main blocks generated by someone else
    -- in the past 'mdNoBlocksSlotThreshold' slots, it's bad and we've
    -- been eclipsed.  Here's how we determine that a block is good
    -- (i.e. main block generated not by us):
    isGoodBlock (Left _)   = False
    isGoodBlock (Right mb) = mb ^. headerLeaderKey /= ourPk
    -- Okay, now let's iterate until we see a good blocks or until we
    -- go past the threshold and there's no point in looking anymore:
    notEclipsed header = do
        let prevBlock = header ^. prevBlockL
        if | pastThreshold header     -> pure False
           | prevBlock == genesisHash -> pure True
           | isGoodBlock header       -> pure True
           | otherwise                ->
                 getBlockHeader prevBlock >>= \case
                     Just h  -> notEclipsed h
                     Nothing -> onBlockLoadFailure header $> True

checkForReceivedBlocksWorkerImpl
    :: WorkMode ssc m
    => SendActions m -> m ()
checkForReceivedBlocksWorkerImpl sendActions =
    afterDelay . repeatOnInterval . reportingFatal version $ do
        ourPk <- ncPublicKey <$> getNodeContext
        let onSlotDefault slotId = do
                header <- getTipBlockHeader
                unlessM (checkEclipsed ourPk slotId header) onEclipsed
        maybe onSlotUnknown onSlotDefault =<< getCurrentSlot
  where
    afterDelay action = delay (sec 3) >> action
    onSlotUnknown = do
        logNotice "Current slot not known. Will try to trigger recovery."
        triggerRecovery sendActions
    onEclipsed = do
        logWarning $
            "Our neighbors are likely trying to carry out an eclipse attack! " <>
            "There are no blocks younger " <>
            "than 'mdNoBlocksSlotThreshold' that we didn't generate " <>
            "by ourselves"
        triggerRecovery sendActions
        reportEclipse
    repeatOnInterval action = runIfNotShutdown $ do
        () <- action
        slotDur <- getLastKnownSlotDuration
        delay $ min slotDur $ convertUnit (sec 20)
        repeatOnInterval action
    reportEclipse = do
        bootstrapMin <- (+ sec 10) . convertUnit <$> getLastKnownSlotDuration
        nonTrivialUptime <- (> bootstrapMin) <$> getUptime
        isRecovery <- isRecoveryMode
        let reason =
                "Eclipse attack was discovered, mdNoBlocksSlotThreshold: " <>
                show (mdNoBlocksSlotThreshold :: Int)
        when (nonTrivialUptime && not isRecovery) $
            reportMisbehaviourMasked version reason

checkForIgnoredCommitmentsWorker
    :: forall m.
       WorkMode SscGodTossing m
    => (WorkerSpec m, OutSpecs)
checkForIgnoredCommitmentsWorker = localWorker $ do
    epochIdx <- atomically (newTVar 0)
    _ <- runReaderT (onNewSlot True checkForIgnoredCommitmentsWorkerImpl) epochIdx
    return ()

checkForIgnoredCommitmentsWorkerImpl
    :: forall m. WorkMode SscGodTossing m
    => SlotId -> ReaderT (TVar EpochIndex) m ()
checkForIgnoredCommitmentsWorkerImpl slotId = do
    checkCommitmentsInPreviousBlocks slotId
    tvar <- ask
    lastCommitment <- lift $ atomically $ readTVar tvar
    when (siEpoch slotId - lastCommitment > mdNoCommitmentsEpochThreshold) $
        logWarning $ sformat
            ("Our neighbors are likely trying to carry out an eclipse attack! "%
             "Last commitment was at epoch "%int%", "%
             "which is more than 'mdNoCommitmentsEpochThreshold' epochs ago")
            lastCommitment

checkCommitmentsInPreviousBlocks
    :: forall m. WorkMode SscGodTossing m
    => SlotId -> ReaderT (TVar EpochIndex) m ()
checkCommitmentsInPreviousBlocks slotId = do
    kBlocks <- map fst <$> loadBlundsFromTipByDepth blkSecurityParam
    forM_ kBlocks $ \case
        Right blk -> checkCommitmentsInBlock slotId blk
        _         -> return ()

checkCommitmentsInBlock
    :: forall m. WorkMode SscGodTossing m
    => SlotId -> MainBlock SscGodTossing -> ReaderT (TVar EpochIndex) m ()
checkCommitmentsInBlock slotId block = do
    ourId <- addressHash . ncPublicKey <$> getNodeContext
    let commitmentInBlockchain = isCommitmentInPayload ourId (block ^. blockMpc)
    when commitmentInBlockchain $ do
        tvar <- ask
        lift $ atomically $ writeTVar tvar $ siEpoch slotId
  where
    isCommitmentInPayload addr (CommitmentsPayload commitments _) =
        HM.member addr $ getCommitmentsMap commitments
    isCommitmentInPayload _ _ = False
