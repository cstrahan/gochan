module Main where

import           Control.Concurrent             hiding (Chan)
import           Control.Concurrent.GChan
import           Control.Monad
import           System.IO.Unsafe
import           Weigh

main :: IO ()
main =
    mainWith
        (do io "creating a channel" chanConstruction ()
            io "unbuffered send & recv" unbufferedSendRecv chanUnbuffered
            io "unbuffered select send & recv" unselectSendRecv chanUnbuffered
            io "unbuffered recv" simpleRecv chanUnbufferedAlreadySent
            io "unbuffered select recv" unbufferedSendRecv chanUnbufferedAlreadySent
            io "buffered send" simpleSend chanBufferedEmpty
            io "buffered recv" simpleRecv chanBufferedAlreadySent
            io "buffered select send" selectSend chanBufferedEmpty
            io "buffered select recv" selectRecv chanBufferedAlreadySent)

chanConstruction :: () -> IO ()
chanConstruction = const (void (mkChan 0 :: IO (Chan Int)))

unbufferedSendRecv :: Chan Int -> IO ()
unbufferedSendRecv c = do
    forkIO $ chanSend c 0
    chanRecv c
    return ()

unselectSendRecv :: Chan Int -> IO ()
unselectSendRecv c = do
    forkIO $ select [Send c 0 (return ())] Nothing
    select [Recv c (const (return ()))] Nothing
    return ()

simpleSend :: Chan Int -> IO ()
simpleSend c = chanSend c 0

simpleRecv :: Chan Int -> IO ()
simpleRecv c = void (chanRecv c)

selectSend :: Chan Int -> IO ()
selectSend c = select [Send c 0 (return ())] Nothing

selectRecv :: Chan Int -> IO ()
selectRecv c = select [Recv c (const (return ()))] Nothing

--------------------------------------------------------------------------------
-- We don't want these to show up in allocations, so carefully unsafePerformIO
-- here. The threading is scary, but I can't think of any other way to test
-- this, given the concurrent nature of this library.
{-# NOINLINE chanUnbuffered #-}

chanUnbuffered :: Chan Int
chanUnbuffered = unsafePerformIO (mkChan 0)

{-# NOINLINE chanUnbufferedAlreadySent #-}

chanUnbufferedAlreadySent :: Chan Int
chanUnbufferedAlreadySent =
    unsafePerformIO $
    do c <- mkChan 0
       forkIO $ chanSend c 0
       return c

{-# NOINLINE chanBufferedEmpty #-}

chanBufferedEmpty :: Chan Int
chanBufferedEmpty = unsafePerformIO (mkChan 1)

{-# NOINLINE chanBufferedAlreadySent #-}

chanBufferedAlreadySent :: Chan Int
chanBufferedAlreadySent =
    unsafePerformIO $
    do c <- mkChan 1
       chanSend c 0
       return c
