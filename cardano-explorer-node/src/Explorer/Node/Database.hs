{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module Explorer.Node.Database
  ( DbAction (..)
  , DbActionQueue (..)
  , lengthDbActionQueue
  , newDbActionQueue
  , runDbThread
  , writeDbActionQueue
  ) where

import           Cardano.BM.Trace (Trace, logDebug, logError, logInfo)
import           Cardano.Prelude

import qualified Control.Concurrent.STM as STM
import           Control.Concurrent.STM.TBQueue (TBQueue)
import qualified Control.Concurrent.STM.TBQueue as TBQ

import           Control.Monad.Logger (NoLoggingT)
import           Control.Monad.Trans.Except.Extra (newExceptT)

import           Database.Persist.Sql (SqlBackend)

import qualified Explorer.DB as DB
import           Explorer.Node.Error
import           Explorer.Node.Metrics
import           Explorer.Node.Plugin
import           Explorer.Node.Util

import           Ouroboros.Consensus.Ledger.Byron (ByronBlock (..))
import           Ouroboros.Network.Block (BlockNo (..), Point (..))

import qualified System.Metrics.Prometheus.Metric.Gauge as Gauge


data NextState
  = Continue
  | Done

data DbAction
  = DbApplyBlock !ByronBlock !BlockNo
  | DbRollBackToPoint !(Point ByronBlock)
  | DbFinish

newtype DbActionQueue = DbActionQueue
  { dbActQueue :: TBQueue DbAction
  }

lengthDbActionQueue :: DbActionQueue -> STM Natural
lengthDbActionQueue (DbActionQueue q) = STM.lengthTBQueue q

newDbActionQueue :: IO DbActionQueue
newDbActionQueue = DbActionQueue <$> TBQ.newTBQueueIO 2000

writeDbActionQueue :: DbActionQueue -> DbAction -> STM ()
writeDbActionQueue (DbActionQueue q) = TBQ.writeTBQueue q


runDbThread :: Trace IO Text -> ExplorerNodePlugin -> Metrics -> DbActionQueue -> IO ()
runDbThread trce plugin metrics queue = do
    logInfo trce "Running DB thread"
    loop
    logInfo trce "Shutting down DB thread"
  where
    loop = do
      xs <- blockingFlushDbActionQueue queue
      when (length xs > 1) $ do
        logDebug trce $ "runDbThread: " <> textShow (length xs) <> " blocks"
      eNextState <- runExceptT $ runActions trce plugin xs
      mBlkNo <-  DB.runDbNoLogging DB.queryLatestBlockNo
      case mBlkNo of
        Nothing -> pure ()
        Just blkNo -> Gauge.set (fromIntegral blkNo) $ mDbHeight metrics
      case eNextState of
        Left err -> logError trce $ renderExplorerNodeError err
        Right Continue -> loop
        Right Done -> pure ()

-- | Run the list of 'DbAction's. Block are applied in a single set (as a transaction)
-- and other operations are applied one-by-one.
runActions :: Trace IO Text -> ExplorerNodePlugin -> [DbAction] -> ExceptT ExplorerNodeError IO NextState
runActions trce plugin =
    dbAction Continue
  where
    dbAction :: NextState -> [DbAction] -> ExceptT ExplorerNodeError IO NextState
    dbAction next [] = pure next
    dbAction Done _ = pure Done
    dbAction Continue xs =
      case spanDbApply xs of
        ([], DbFinish:_) -> do
            pure Done
        ([], DbRollBackToPoint pt:ys) -> do
            runRollbacks trce plugin pt
            dbAction Continue ys
        (ys, zs) -> do
          insertBlockList trce plugin ys
          if null zs
            then pure Continue
            else dbAction Continue zs

runRollbacks
    :: Trace IO Text
    -> ExplorerNodePlugin
    -> Point ByronBlock
    -> ExceptT ExplorerNodeError IO ()
runRollbacks trce (ExplorerNodePlugin _ rollbackActions) point =
    newExceptT $ foldM rollback (Right ()) rollbackActions
  where
    rollback prevResult action =
      case prevResult of
        Left e -> pure $ Left e
        Right () -> action trce point

insertBlockList
    :: Trace IO Text
    -> ExplorerNodePlugin
    -> [(ByronBlock, BlockNo)]
    -> ExceptT ExplorerNodeError IO ()
insertBlockList trce  (ExplorerNodePlugin insertActions _) blks =
  -- Setting this to True will log all 'Persistent' operations which is great
  -- for debugging, but otherwise is *way* too chatty.
  newExceptT
    . DB.runDbNoLogging
    $ foldM insertBlock (Right ()) blks
  where
    insertBlock
        :: Either ExplorerNodeError ()
        -> (ByronBlock, BlockNo)
        -> ReaderT SqlBackend (NoLoggingT IO) (Either ExplorerNodeError ())
    insertBlock prevResult (blk, blkNo) =
      case prevResult of
        Left e -> pure $ Left e
        Right () -> foldM (insertAction (blk, blkNo)) (Right ()) insertActions

    insertAction (blk, blkNo) prevResult action =
      case prevResult of
        Left e -> pure $ Left e
        Right () -> action trce blk blkNo

-- | Block if the queue is empty and if its not read/flush everything.
-- Need this because `flushTBQueue` never blocks and we want to block until
-- there is one item or more.
-- Use this instead of STM.check to make sure it blocks if the queue is empty.
blockingFlushDbActionQueue :: DbActionQueue -> IO [DbAction]
blockingFlushDbActionQueue (DbActionQueue queue) = do
  STM.atomically $ do
    x <- TBQ.readTBQueue queue
    xs <- TBQ.flushTBQueue queue
    pure $ x : xs

-- | Split the DbAction list into a prefix containing blocks to apply and a postfix.
spanDbApply :: [DbAction] -> ([(ByronBlock, BlockNo)], [DbAction])
spanDbApply lst =
  case lst of
    (DbApplyBlock b n:xs) -> let (ys, zs) = spanDbApply xs in ((b, n):ys, zs)
    xs -> ([], xs)
