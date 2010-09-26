{-# LANGUAGE FlexibleContexts, FlexibleInstances, ScopedTypeVariables, UndecidableInstances #-}

module Control.Parallel.MPI.Storable
   ( send
   , ssend
   , bsend
   , rsend
   , recv
   , bcastSend
   , bcastRecv
   , isend
   , ibsend
   , issend
   , irecv
   , sendScatter
   , recvScatter
   , sendScatterv
   , recvScatterv
   , sendGather
   , recvGather
   , sendGatherv
   , recvGatherv
   , allgather
   , allgatherv
   , alltoall
   , alltoallv
   , withNewArray
   , withNewArray_
   , withNewVal
   , withNewVal_
   , withNewBS
   , withNewBS_
   ) where

import C2HS
import Data.Array.Base (unsafeNewArray_)
import Data.Array.IO
import Data.Array.Storable
import Control.Applicative ((<$>))
import Data.ByteString.Unsafe as BS
import qualified Data.ByteString as BS
import qualified Control.Parallel.MPI.Internal as Internal
import Control.Parallel.MPI.Datatype as Datatype
import Control.Parallel.MPI.Comm as Comm
import Control.Parallel.MPI.Status as Status
import Control.Parallel.MPI.Utils (checkError)
import Control.Parallel.MPI.Tag as Tag
import Control.Parallel.MPI.Rank as Rank
import Control.Parallel.MPI.Request as Request

-- | if the user wants to call recvScatterv for the first time without
-- already having allocated the array, then they can call it like so:
--
-- (array,_) <- withNewArray range $ recvScatterv root comm
--
-- and thereafter they can call it like so:
--
--  recvScatterv root comm array
withNewArray :: (Ix i, MArray a e m, MpiDst (a i e)) => (i, i) -> (a i e -> m r) -> m (a i e, r)
withNewArray range f = do
  arr <- unsafeNewArray_ range -- New, uninitialized array, According to http://hackage.haskell.org/trac/ghc/ticket/3586
                               -- should be faster than newArray_
  res <- f arr
  return (arr, res)

-- | Same as withRange, but discards the result of the processor function
withNewArray_ :: (Ix i, MArray a e m, MpiDst (a i e)) => (i, i) -> (a i e -> m r) -> m (a i e)
withNewArray_ range f = do
  arr <- unsafeNewArray_ range
  _ <- f arr
  return arr

send, bsend, ssend, rsend :: (MpiSrc v) => Comm -> Rank -> Tag -> v -> IO ()
send  = sendWith Internal.send
bsend = sendWith Internal.bsend
ssend = sendWith Internal.ssend
rsend = sendWith Internal.rsend

type SendPrim = Ptr () -> CInt -> Datatype -> CInt -> CInt -> Comm -> IO CInt

sendWith :: (MpiSrc v) => SendPrim -> Comm -> Rank -> Tag -> v -> IO ()
sendWith send_function comm rank tag val = do
   sendFrom val $ \valPtr numBytes dtype -> do
      checkError $ send_function (castPtr valPtr) numBytes dtype (fromRank rank) (fromTag tag) comm

recv :: (MpiDst v) => Comm -> Rank -> Tag -> v -> IO Status
recv comm rank tag arr = do
   recvInto arr $ \valPtr numBytes dtype ->
      alloca $ \statusPtr -> do
         checkError $ Internal.recv (castPtr valPtr) numBytes dtype (fromRank rank) (fromTag tag) comm (castPtr statusPtr)
         peek statusPtr

bcastSend :: (MpiSrc v) => Comm -> Rank -> v -> IO ()
bcastSend comm sendRank val = do
   sendFrom val $ \valPtr numBytes dtype -> do
      checkError $ Internal.bcast (castPtr valPtr) numBytes dtype (fromRank sendRank) comm

bcastRecv :: (MpiDst v) => Comm -> Rank -> v -> IO ()
bcastRecv comm sendRank val = do
   recvInto val $ \valPtr numBytes dtype -> do
      checkError $ Internal.bcast (castPtr valPtr) numBytes dtype (fromRank sendRank) comm

isend, ibsend, issend :: (MpiSrc v) => Comm -> Rank -> Tag -> v -> IO Request
isend  = isendWith Internal.isend
ibsend = isendWith Internal.ibsend
issend = isendWith Internal.issend

type ISendPrim = Ptr () -> CInt -> Datatype -> CInt -> CInt -> Comm -> Ptr (Request) -> IO CInt

isendWith :: (MpiSrc v) => ISendPrim -> Comm -> Rank -> Tag -> v -> IO Request
isendWith send_function comm recvRank tag val = do
   sendFrom val $ \valPtr numBytes dtype ->
      alloca $ \requestPtr -> do
         checkError $ send_function (castPtr valPtr) numBytes dtype (fromRank recvRank) (fromTag tag) comm requestPtr
         peek requestPtr

{-
   At the moment we are limiting this to StorableArrays because they
   are compatible with C pointers. This means that the recieved data can
   be written directly to the array, and does not have to be copied out
   at the end. This is important for the non-blocking operation of irecv.
   It is not safe to copy the data from the C pointer until the transfer
   is complete. So any array type which required copying of data after
   receipt of the message would have to wait on complete transmission.
   It is not clear how to incorporate the waiting automatically into
   the same interface as the one below. One option is to use a Haskell
   thread to do the data copying in the "background". Another option
   is to introduce a new kind of data handle which would encapsulate the
   wait operation, and would allow the user to request the data to be
   copied when the wait was complete.
-}
irecv :: (Storable e, Ix i, UnderlyingMpiDatatype e) => Comm -> Rank -> Tag -> StorableArray i e -> IO Request
irecv comm sendRank tag recvVal = do
   alloca $ \requestPtr ->
      recvInto recvVal $ \recvPtr recvElements recvType -> do
         checkError $ Internal.irecv (castPtr recvPtr) recvElements recvType (fromRank sendRank) (fromTag tag) comm requestPtr
         peek requestPtr

sendScatter :: (MpiSrc v1, MpiDst v2) => Comm -> Rank -> v1 -> v2 -> IO ()
sendScatter comm root sendVal recvVal = do
   recvInto recvVal $ \recvPtr recvElements recvType ->
     sendFrom sendVal $ \sendPtr _ _ ->
       checkError $ Internal.scatter (castPtr sendPtr) recvElements recvType (castPtr recvPtr) recvElements recvType (fromRank root) comm

recvScatter :: (MpiDst v) => Comm -> Rank -> v -> IO ()
recvScatter comm root recvVal = do
   recvInto recvVal $ \recvPtr recvElements recvType ->
     checkError $ Internal.scatter nullPtr 0 byte (castPtr recvPtr) recvElements recvType (fromRank root) comm

{-
For Scatterv/Gatherv we need arrays of "stripe lengths" and displacements.

Sometimes it would be easy for end-user to furnish those array, sometimes not.

We could steal the useful idea from mpy4pi and allow user to specify counts and displacements in several
ways - as a number, an "empty" value, or a list/array of values. Semantic is as following:

| count  | displacement | meaning                                                                                  |
|--------+--------------+------------------------------------------------------------------------------------------|
| number | nothing      | Uniform stripes of the given size, placed next to each other                             |
| number | number       | Uniform stripes of the given size, with "displ" values between them                      |
| number | vector       | Uniform stripes of the given size, at given displacements (we could check for overlap)   |
| vector | nothing      | Stripe lengths are given, compute the displacements assuming they are contiguous         |
| vector | number       | Stripe lengths are given, compute the displacements allowing "displ" values between them |
| vector | vector       | Stripes and displacements are pre-computed elsewhere                                     |


We could codify this with typeclass:

class CountsAndDisplacements a b where
  getCountsDisplacements :: (Ix i) => (i,i) -> a -> b -> (StorableArray Int Int, StorableArray Int Int)

instance CountsAndDisplacements Int Int where
  getCountsDisplacements bnds c d = striped bnds c d

instance CountsAndDisplacements Int (Maybe Int) where
  getCountsDisplacements bnds c Nothing  = striped bnds c 0
  getCountsDisplacements bnds c (Just d) = striped bnds c d

instance CountsAndDisplacements Int (StorableArray Int Int) where
  getCountsDisplacements bnds n displs  = countsOnly bnds n

instance CountsAndDisplacements (StorableArray Int Int) (Maybe Int) where
  getCountsDisplacements bnds cs Nothing  = displacementsFromCounts cs 0
  getCountsDisplacements bnds cs (Just d) = displacementsFromCounts cs d

instance CountsAndDisplacements (StorableArray Int Int) (StorableArray Int Int) where
  getCountsDisplacements bnds cs ds  = (cs,ds)

striped  = undefined
countsOnly = undefined
displacementsFromCounts = undefined

What do you think?
-}

-- Counts and displacements should be presented in ready-for-use form for speed, hence the choice of StorableArrays
-- See Serializable for other alternatives.

-- receiver needs comm rank recvcount
-- sender needs everything else
sendScatterv :: (MpiSrc v1, MpiDst v2) => Comm -> Rank -> v1 ->
                 StorableArray Int Int -> StorableArray Int Int -> v2 -> IO ()
sendScatterv comm root sendVal counts displacements recvVal  = do
   -- myRank <- commRank comm
   -- XXX: assert myRank == sendRank ?
   recvInto recvVal $ \recvPtr recvElements recvType ->
     sendFrom sendVal $ \sendPtr _ sendType->
       withStorableArray counts $ \countsPtr ->
         withStorableArray displacements $ \displPtr ->
           checkError $ Internal.scatterv (castPtr sendPtr) (castPtr countsPtr) (castPtr displPtr) sendType
                        (castPtr recvPtr) recvElements recvType (fromRank root) comm

recvScatterv :: (MpiDst v) => Comm -> Rank -> v -> IO ()
recvScatterv comm root arr = do
   -- myRank <- commRank comm
   -- XXX: assert (myRank /= sendRank)
   recvInto arr $ \recvPtr recvElements recvType ->
     checkError $ Internal.scatterv nullPtr nullPtr nullPtr byte (castPtr recvPtr) recvElements recvType (fromRank root) comm

{-
XXX we should check that the recvArray is large enough to store:

   segmentSize * commSize
-}
recvGather :: (MpiSrc v1, MpiDst v2) => Comm -> Rank -> v1 -> v2 -> IO ()
recvGather comm root segment recvVal = do
   -- myRank <- commRank comm
   -- XXX: assert myRank == root
   sendFrom segment $ \sendPtr sendElements sendType ->
     recvInto recvVal $ \recvPtr _ _ ->
       checkError $ Internal.gather (castPtr sendPtr) sendElements sendType (castPtr recvPtr) sendElements sendType 
                    (fromRank root) comm

sendGather :: (MpiSrc v) => Comm -> Rank -> v -> IO ()
sendGather comm root segment = do
   -- myRank <- commRank comm
   -- XXX: assert it is /= root
   sendFrom segment $ \sendPtr sendElements sendType ->
     -- the recvPtr is ignored in this case, so we can make it NULL, likewise recvCount can be 0
     checkError $ Internal.gather (castPtr sendPtr) sendElements sendType nullPtr 0 byte (fromRank root) comm

recvGatherv :: (MpiSrc v1, MpiDst v2) => Comm -> Rank -> v1 ->
                StorableArray Int Int -> StorableArray Int Int -> v2 -> IO ()
recvGatherv comm root segment counts displacements recvVal = do
   -- myRank <- commRank comm
   -- XXX: assert myRank == root
   sendFrom segment $ \sendPtr sendElements sendType ->
     withStorableArray counts $ \countsPtr ->
        withStorableArray displacements $ \displPtr ->
          recvInto recvVal $ \recvPtr _ recvType->
            checkError $ Internal.gatherv (castPtr sendPtr) sendElements sendType (castPtr recvPtr)
                         (castPtr countsPtr) (castPtr displPtr) recvType (fromRank root) comm

sendGatherv :: (MpiSrc v) => Comm -> Rank -> v -> IO ()
sendGatherv comm root segment = do
   -- myRank <- commRank comm
   -- XXX: assert myRank == root
   sendFrom segment $ \sendPtr sendElements sendType ->
     -- the recvPtr, counts and displacements are ignored in this case, so we can make it NULL
     checkError $ Internal.gatherv (castPtr sendPtr) sendElements sendType nullPtr nullPtr nullPtr byte (fromRank root) comm

allgather :: (MpiSrc v1, MpiDst v2) => Comm -> v1 -> v2 -> IO ()
allgather comm sendVal recvVal = do
  sendFrom sendVal $ \sendPtr sendElements sendType ->
    recvInto recvVal $ \recvPtr _ _ -> -- Since amount sent equals amount received
      checkError $ Internal.allgather (castPtr sendPtr) sendElements sendType (castPtr recvPtr) sendElements sendType comm

allgatherv :: (MpiSrc v1, MpiDst v2) => Comm -> v1 -> StorableArray Int Int -> StorableArray Int Int -> v2 -> IO ()
allgatherv comm segment counts displacements recvVal = do
   sendFrom segment $ \sendPtr sendElements sendType ->
     withStorableArray counts $ \countsPtr ->  
        withStorableArray displacements $ \displPtr -> 
          recvInto recvVal $ \recvPtr _ recvType ->
            checkError $ Internal.allgatherv (castPtr sendPtr) sendElements sendType (castPtr recvPtr) (castPtr countsPtr) (castPtr displPtr) recvType comm
             
-- XXX: when sending arrays, we can not measure the size of the array element with sizeOf here without
-- breaking the abstraction. Hence for now `sendCount' should be treated as "count of the underlying MPI
-- representation elements that have to be sent to each process". User is expected to know that type and its size.
alltoall :: forall v1 v2.(MpiSrc v1, MpiDst v2) => Comm -> v1 -> Int -> v2 -> IO ()
alltoall comm sendVal sendCount recvVal = do
  let sendCount_ = cIntConv sendCount
  sendFrom sendVal $ \sendPtr _ sendType ->
    recvInto recvVal $ \recvPtr _ _ -> -- Since amount sent must equal amount received
      checkError $ Internal.alltoall (castPtr sendPtr) sendCount_ sendType (castPtr recvPtr) sendCount_ sendType comm

alltoallv :: forall v1 v2.(MpiSrc v1, MpiDst v2) => Comm -> v1 -> StorableArray Int Int -> StorableArray Int Int -> StorableArray Int Int -> StorableArray Int Int -> v2 -> IO ()
alltoallv comm sendVal sendCounts sendDisplacements recvCounts recvDisplacements recvVal = do
  sendFrom sendVal $ \sendPtr _ sendType ->
    recvInto recvVal $ \recvPtr _ recvType ->
      withStorableArray sendCounts $ \sendCountsPtr ->
        withStorableArray sendDisplacements $ \sendDisplPtr ->
          withStorableArray recvCounts $ \recvCountsPtr ->
            withStorableArray recvDisplacements $ \recvDisplPtr ->
              checkError $ Internal.alltoallv (castPtr sendPtr) (castPtr sendCountsPtr) (castPtr sendDisplPtr) sendType
                                              (castPtr recvPtr) (castPtr recvCountsPtr) (castPtr recvDisplPtr) recvType comm
  
class UnderlyingMpiDatatype e where
  representation :: e -> Datatype
  
instance UnderlyingMpiDatatype Int where
  representation _ = int

instance UnderlyingMpiDatatype CInt where
  representation _ = int

instance UnderlyingMpiDatatype CChar where
  representation _ = byte

instance UnderlyingMpiDatatype (StorableArray i e) where
  representation _ = byte

instance UnderlyingMpiDatatype (IOArray i e) where
  representation _ = byte
  
instance UnderlyingMpiDatatype (IOUArray i e) where
  representation _ = byte
  
instance UnderlyingMpiDatatype BS.ByteString where
  representation _ = byte

-- Note that 'e' is not bound by the typeclass, so all kinds of foul play
-- are possible. However, since MPI declares all buffers as 'void*' anyway, 
-- we are not making life all _that_ unsafe with this
class MpiSrc v where
   sendFrom :: v -> (Ptr e -> CInt -> Datatype -> IO a) -> IO a

class MpiDst v where
   recvInto :: v -> (Ptr e -> CInt -> Datatype -> IO a) -> IO a

-- Sending from a single Storable values
instance MpiSrc CInt where
  sendFrom = sendFromSingleValue
instance MpiSrc Int where
  sendFrom x = sendFromSingleValue (cIntConv x :: CInt)

sendFromSingleValue :: (UnderlyingMpiDatatype v, Storable v) => v -> (Ptr e -> CInt -> Datatype -> IO a) -> IO a
sendFromSingleValue v f = do
  alloca $ \ptr -> do
    poke ptr v
    f (castPtr ptr) (1::CInt) (representation v)
  
-- Sending-receiving arrays of such values
instance (Storable e, Ix i) => MpiSrc (StorableArray i e) where
  sendFrom = withStorableArrayAndSize

instance (Storable e, Ix i) => MpiDst (StorableArray i e) where
  recvInto = withStorableArrayAndSize

withStorableArrayAndSize :: forall a i e z.(Storable e, Ix i) => StorableArray i e -> (Ptr z -> CInt -> Datatype -> IO a) -> IO a
withStorableArrayAndSize arr f = do
   rSize <- rangeSize <$> getBounds arr
   let numBytes = cIntConv (rSize * sizeOf (undefined :: e))
   withStorableArray arr $ \ptr -> f (castPtr ptr) numBytes (representation (undefined :: StorableArray i e))

-- Same, for IOArray
instance (Storable e, UnderlyingMpiDatatype (IOArray i e), Ix i) => MpiSrc (IOArray i e) where
  sendFrom = sendWithMArrayAndSize
instance (Storable e, UnderlyingMpiDatatype (IOArray i e), Ix i) => MpiDst (IOArray i e) where
  recvInto = recvWithMArrayAndSize

recvWithMArrayAndSize :: forall i e r a z. (Storable e, Ix i, MArray a e IO, UnderlyingMpiDatatype (a i e)) => a i e -> (Ptr z -> CInt -> Datatype -> IO r) -> IO r
recvWithMArrayAndSize array f = do
   bounds <- getBounds array
   let numElements = rangeSize bounds
   let elementSize = sizeOf (undefined :: e)
   let numBytes = cIntConv (numElements * elementSize)
   allocaArray numElements $ \ptr -> do
      result <- f (castPtr ptr) numBytes (representation (undefined :: a i e))
      fillArrayFromPtr (range bounds) numElements ptr array
      return result

sendWithMArrayAndSize :: forall i e r a z. (Storable e, Ix i, MArray a e IO, UnderlyingMpiDatatype (a i e)) => a i e -> (Ptr z -> CInt -> Datatype -> IO r) -> IO r
sendWithMArrayAndSize array f = do
   elements <- getElems array
   bounds <- getBounds array
   let numElements = rangeSize bounds
   let elementSize = sizeOf (undefined :: e)
   let numBytes = cIntConv (numElements * elementSize)
   withArray elements $ \ptr -> f (castPtr ptr) numBytes (representation (undefined :: a i e))

-- XXX I wonder if this can be written without the intermediate list?
-- Maybe GHC can elimiate it. We should look at the generated compiled
-- code to see how well the loop is handled.
fillArrayFromPtr :: (MArray a e IO, Storable e, Ix i) => [i] -> Int -> Ptr e -> a i e -> IO ()
fillArrayFromPtr indices numElements startPtr array = do
   elems <- peekArray numElements startPtr
   mapM_ (\(index, element) -> writeArray array index element ) (zip indices elems)

-- ByteString
instance MpiSrc BS.ByteString where
  sendFrom = sendWithByteStringAndSize

sendWithByteStringAndSize :: BS.ByteString -> (Ptr z -> CInt -> Datatype -> IO a) -> IO a
sendWithByteStringAndSize bs f = do
  unsafeUseAsCStringLen bs $ \(bsPtr,len) -> f (castPtr bsPtr) (cIntConv len) byte

-- Pointers to storable with known on-wire representation
instance (Storable e, UnderlyingMpiDatatype e) => MpiDst (Ptr e) where
  recvInto = recvIntoElemPtr (representation (undefined :: e))
    where
      recvIntoElemPtr datatype p f = f (castPtr p) 1 datatype

instance (Storable e, UnderlyingMpiDatatype e) => MpiDst (Ptr e, Int) where
  recvInto = recvIntoVectorPtr (representation (undefined :: e))
    where
      recvIntoVectorPtr datatype (p,len) f = f (castPtr p) (cIntConv len :: CInt) datatype

withNewVal :: (Storable e) => (Ptr e -> IO r) -> IO (e, r)
withNewVal f = do
  alloca $ \ptr -> do
    res <- f ptr
    val <- peek ptr
    return (val, res)

withNewVal_ :: (Storable e) => (Ptr e -> IO r) -> IO e
withNewVal_ f = do
  (val, _) <- withNewVal f
  return val

-- Receiving into new bytestrings
withNewBS :: Int -> ((Ptr CChar,Int) -> IO r) -> IO (BS.ByteString, r)
withNewBS len f = do
  allocaBytes len $ \ptr -> do
    res <- f (ptr, len)
    bs <- BS.packCStringLen (ptr, len)
    return (bs, res)

withNewBS_ :: Int -> ((Ptr CChar,Int) -> IO r) -> IO BS.ByteString
withNewBS_ len f = do
  (bs, _) <- withNewBS len f
  return bs
