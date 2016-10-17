{-# LANGUAGE LambdaCase #-}

module Main where

import           Control.Concurrent             hiding (Chan)
import           Control.Concurrent.GoChan
import           Control.Monad
import           Data.IORef
import           Test.Hspec

main :: IO ()
main =
    hspec $
    do describe "with buffer size 0" $
           do it "chanMake doesn't blow up" $ do void (chanMake 0 :: IO (Chan Int))
              it "send & recv doesn't blow up" $ do sendRecv 0 1 10 sendN drain
              it "send & recv/select doesn't blow up" $
                  do sendRecv 0 1 10 sendN drainSelect
              it "send/select & recv doesn't blow up" $
                  do sendRecv 0 1 10 sendNSelect drain
              it "send/select & recv/select doesn't blow up" $
                  do sendRecv 0 1 10 sendNSelect drainSelect
              it "multi-case select doesn't blow up" $ do multiTest 0
       describe "with buffer size 1" $
           do it "chanMake doesn't blow up" $ void (chanMake 1 :: IO (Chan Int))
              it "send & recv doesn't blow up" $ do sendRecv 1 1 10 sendN drain
              it "send & recv/select doesn't blow up" $
                  do sendRecv 1 1 10 sendN drainSelect
              it "send/select & recv doesn't blow up" $
                  do sendRecv 1 1 10 sendNSelect drain
              it "send/select & recv/select doesn't blow up" $
                  do sendRecv 1 1 10 sendNSelect drainSelect
              it "multi-case select doesn't blow up" $ do multiTest 1
       describe "with buffer size 2" $
           do it "chanMake doesn't blow up" $ void (chanMake 2 :: IO (Chan Int))
              it "send & recv doesn't blow up" $ do sendRecv 2 1 10 sendN drain
              it "send & recv/select doesn't blow up" $
                  do sendRecv 2 1 10 sendN drainSelect
              it "send/select & recv doesn't blow up" $
                  do sendRecv 2 1 10 sendNSelect drain
              it "send/select & recv/select doesn't blow up" $
                  do sendRecv 2 1 10 sendNSelect drainSelect
              it "multi-case select doesn't blow up" $ do multiTest 2
       describe "with buffer size 3" $
           do it "chanMake doesn't blow up" $ do void (chanMake 3 :: IO (Chan Int))
              it "send & recv doesn't blow up" $ do sendRecv 3 1 10 sendN drain
              it "send & recv/select doesn't blow up" $
                  do sendRecv 3 1 10 sendN drainSelect
              it "send/select & recv doesn't blow up" $
                  do sendRecv 3 1 10 sendNSelect drain
              it "send/select & recv/select doesn't blow up" $
                  do sendRecv 3 1 10 sendNSelect drainSelect
              it "multi-case select doesn't blow up" $ do multiTest 3

type Sender = Chan Int -> Int -> Int -> IO ()

type Drainer = Chan Int -> (Int -> IO ()) -> IO () -> IO ()

drain :: Drainer
drain ch recvAct closeAct = do
    mn <- chanRecv ch
    case mn of
        Msg n -> do
            recvAct n
            drain ch recvAct closeAct
        _ -> closeAct

drainSelect :: Drainer
drainSelect ch recvAct closeAct = do
    chanSelect
        [ Recv
              ch
              (\case
                   Msg n -> do
                       recvAct n
                       drainSelect ch recvAct closeAct
                   _ -> closeAct)]
        Nothing

sendN :: Sender
sendN ch low hi = do
    chanSend ch low
    when (low < hi) (sendN ch (low + 1) hi)

sendNSelect :: Sender
sendNSelect ch low hi = do
    chanSelect [Send ch low (return ())] Nothing
    when (low < hi) (sendNSelect ch (low + 1) hi)

sendRecv :: Int -> Int -> Int -> Sender -> Drainer -> Expectation
sendRecv size low hi sender drainer = do
    lock <- newEmptyMVar
    c <- chanMake size
    totalRef <- newIORef 0
    forkIO $
        do sender c low hi
           chanClose c
    drainer
        c
        (\n ->
              modifyIORef' totalRef (+ n))
        (when (size > 0) (putMVar lock ()))
    readIORef totalRef
    -- when the channel is un-buffered, draining should act as synchronization;
    -- only lock when the buffer size is greater than 0.
    when
        (size > 0)
        (takeMVar lock)
    total <- readIORef totalRef
    total `shouldBe` sum [low .. hi]

multiTest :: Int -> Expectation
multiTest size = do
    lock1 <- newEmptyMVar
    lock2 <- newEmptyMVar
    c1 <- chanMake size
    c2 <- chanMake size
    c1sentRef <- newIORef 0
    c1recvdRef <- newIORef 0
    c2sentRef <- newIORef 0
    c2recvdRef <- newIORef 0
    forkIO $ ping2 c1sentRef c2sentRef c1 c2 0 (putMVar lock2 ())
    pong2 c1recvdRef c2recvdRef c1 c2 0 (putMVar lock1 ())
    takeMVar lock1
    takeMVar lock2
    c1sent <- readIORef c1sentRef
    c1recvd <- readIORef c1recvdRef
    c2sent <- readIORef c2sentRef
    c2recvd <- readIORef c2recvdRef
    -- each channel should recv as often as it is sent on.
    (c1sent, c2sent) `shouldBe`
        (c1recvd, c2recvd)

ping2
    :: IORef Int
    -> IORef Int
    -> Chan Int
    -> Chan Int
    -> Int
    -> IO ()
    -> IO ()
ping2 ref1 ref2 c1 c2 n doneAct = do
    if (n < 20)
        then do
            chanSelect
                [ Send c1 n (void (modifyIORef' ref1 (+ 1)))
                , Send c2 n (void (modifyIORef' ref2 (+ 1)))]
                Nothing
            ping2 ref1 ref2 c1 c2 (n + 1) doneAct
        else doneAct

pong2
    :: IORef Int
    -> IORef Int
    -> Chan Int
    -> Chan Int
    -> Int
    -> IO ()
    -> IO ()
pong2 ref1 ref2 c1 c2 n doneAct = do
    if (n < 20)
        then do
            chanSelect
                [ Recv
                      c1
                      (\case
                           Msg n -> modifyIORef' ref1 (+ 1))
                , Recv
                      c2
                      (\case
                           Msg n -> modifyIORef' ref2 (+ 1))]
                Nothing
            pong2 ref1 ref2 c1 c2 (n + 1) doneAct
        else doneAct
