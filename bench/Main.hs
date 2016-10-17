{-# LANGUAGE BangPatterns #-}

module Main where

import           Control.Concurrent             hiding (Chan)
import           Control.Concurrent.GoChan
import           Control.Monad
import           Criterion.Main
import           System.Random

for xs f = map f xs

main :: IO ()
main =
    defaultMain $
    (for
         [0, 2, 5]
         (\size ->
               bgroup
                   ("buffer size " ++ show size)
                   [ bench "create" $ whnfIO (chanMake size :: IO (Chan Int))
                   , bench "send & recv" $ whnfIO (sendRecv size)
                   , bench "select send & recv with 1 case" $
                     whnfIO (select1 size)
                   , bench "select send & recv with 2 case" $
                     whnfIO (select2 size)
                   , bench "select send & recv with 3 case" $
                     whnfIO (select3 size)])) ++
    [bench "no-threads send & recv" $ whnfIO sendRecvBuf]

{-# INLINE iters #-}

iters = 15

sendRecv :: Int -> IO ()
sendRecv !size = do
    c <- chanMake size
    forkIO $
        do sendN c 0
           chanClose c
    drain c
  where
    drain !ch = do
        mn <- chanRecv ch
        case mn of
            Msg n -> do
                drain ch
            _ -> return ()
    sendN !ch !n = do
        chanSend ch n
        when (n < iters) (sendN ch (n + 1))

sendRecvBuf :: IO ()
sendRecvBuf = do
    c <- chanMake 1
    sendRecN c
  where
    sendRecN !ch = do
        chanSend ch 42
        void $ chanRecv ch

select1
    :: Int -> IO ()
select1 !size = do
    c1 <- chanMake size
    forkIO $ ping c1 0
    pong c1 0
  where
    ping !c1 !n = do
        if (n < iters)
            then do
                chanSelect [Send c1 n (return ())] Nothing
                ping c1 (n + 1)
            else return ()
    pong !c1 !n = do
        if (n < iters)
            then do
                chanSelect [Recv c1 (const (return ()))] Nothing
                pong c1 (n + 1)
            else return ()

select2 :: Int -> IO ()
select2 !size = do
    --lock <- newEmptyMVar
    c1 <- chanMake size
    c2 <- chanMake size
    forkIO $ ping c1 c2 0
    pong c1 c2 0
  where
    ping :: Chan Int -> Chan Int -> Int -> IO ()
    ping !c1 !c2 !n = do
        if (n < iters)
            then do
                chanSelect [Send c1 n (return ()), Send c2 n (return ())] Nothing
                ping c1 c2 (n + 1)
            else return ()
    pong :: Chan Int -> Chan Int -> Int -> IO ()
    pong !c1 !c2 !n = do
        if (n < iters)
            then do
                chanSelect
                    [Recv c1 (const (return ())), Recv c2 (const (return ()))]
                    Nothing
                pong c1 c2 (n + 1)
            else return ()

select3 :: Int -> IO ()
select3 !size = do
    --lock <- newEmptyMVar
    c1 <- chanMake size
    c2 <- chanMake size
    c3 <- chanMake size
    forkIO $ ping c1 c2 c3 0
    pong c1 c2 c3 0
  where
    ping !c1 !c2 !c3 !n = do
        if (n < iters)
            then do
                chanSelect
                    [ Send c1 n (return ())
                    , Send c2 n (return ())
                    , Send c3 n (return ())]
                    Nothing
                ping c1 c2 c3 (n + 1)
            else return ()
    pong !c1 !c2 !c3 !n = do
        if (n < iters)
            then do
                chanSelect
                    [ Recv c1 (const (return ()))
                    , Recv c2 (const (return ()))
                    , Recv c3 (const (return ()))]
                    Nothing
                pong c1 c2 c3 (n + 1)
            else return ()
