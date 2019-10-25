{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module Explorer.Node.Metrics
  ( Metrics (..),
    makeMetrics,
    registerMetricsServer,
  )
where

import Cardano.Prelude
import System.Metrics.Prometheus.Concurrent.RegistryT
  ( RegistryT (..),
    registerGauge,
    runRegistryT,
    unRegistryT,
  )
import System.Metrics.Prometheus.Http.Scrape (serveHttpTextMetricsT)
import System.Metrics.Prometheus.Metric.Gauge (Gauge)

data Metrics
  = Metrics
      { mDbHeight :: !Gauge,
        mNodeHeight :: !Gauge,
        mQueuePre :: !Gauge,
        mQueuePost :: !Gauge,
        mQueuePostWrite :: !Gauge
      }

registerMetricsServer :: IO (Metrics, Async ())
registerMetricsServer =
  runRegistryT $ do
    metrics <- makeMetrics
    registry <- RegistryT ask
    server <- liftIO . async $ runReaderT (unRegistryT $ serveHttpTextMetricsT 8080 []) registry
    pure (metrics, server)

makeMetrics :: RegistryT IO Metrics
makeMetrics =
  Metrics
    <$> registerGauge "db_block_height" mempty
    <*> registerGauge "remote_tip_height" mempty
    <*> registerGauge "action_queue_length_pre" mempty
    <*> registerGauge "action_queue_length_post" mempty
    <*> registerGauge "action_queue_length_post_write" mempty
