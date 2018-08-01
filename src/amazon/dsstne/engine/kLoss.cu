/*


   Copyright 2016  Amazon.com, Inc. or its affiliates. All Rights Reserved.

   Licensed under the Apache License, Version 2.0 (the "License"). You may not use this file except in compliance with the License. A copy of the License is located at

   http://aws.amazon.com/apache2.0/

   or in the "license" file accompanying this file. This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
 */

#include "GpuTypes.h"
#include "NNTypes.h"
#include <limits>

static __constant__ GpuData cData;

void SetKLossGpuData()
{
    cudaError_t status;
    status = cudaMemcpyToSymbol(cData, &(getGpu()._data), sizeof(GpuData));     
    RTERROR(status, "cudaMemcpyToSymbol: SetKernelsGpuData copy to cData failed");
}

void GetKLossGpuData()
{
    cudaError_t status;
    status = cudaMemcpyFromSymbol(&(getGpu()._data), cData, sizeof(GpuData));     
    RTERROR(status, "cudaMemcpyFromSymbol: SetKernelsGpuData copy From cData failed");
}

__global__ void
LAUNCH_BOUNDS()
kCalculateSparseRawL1Error_kernel(uint32_t position, NNFloat* pSparseWeight, NNFloat* pUnit, uint64_t stride, uint64_t size)
{
    uint64_t pos                = blockDim.x * blockIdx.x + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < size)
    {
        NNFloat w               = (NNFloat)1.0;
        if (pSparseWeight != NULL)
        {
            uint64_t dpos       = (pos / stride) + position;
            dpos                = cData._bShuffleIndices ? cData._pShuffleIndex[dpos] : dpos;
            w                  *= pSparseWeight[dpos];
        }

        NNFloat a               = pUnit[pos];
        error                   = w * fabsf(a);     
    }
    
    REDUCEERROR(error)
}

__global__ void
LAUNCH_BOUNDS()
kCalculateSparseNonZeroL1Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        uint64_t offset         = pos * stride;
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            error              += w * (fabsf(a - (NNFloat)1.0) - fabsf(a));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

__global__ void
LAUNCH_BOUNDS()
kCalculateSparseOnlyNonZeroL1Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            error              += w * fabsf(a - (NNFloat)1.0);   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}



NNFloat kCalculateSparseL1Error(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight, bool bSparseIgnoreZero)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    if (bSparseIgnoreZero)
    {
        uint32_t blocks             = CalculateBlocks(batch * getGpu()._warpSize);    
        kCalculateSparseOnlyNonZeroL1Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
        LAUNCHERROR("kCalculateSparseOnlyNonZeroL1Error_kernel");    
    }
    else
    {
        uint64_t size               = (uint64_t)batch * (uint64_t)stride;
        uint32_t blocks             = CalculateBlocks(size);    
        kCalculateSparseRawL1Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, pSparseWeight, pUnit, stride, size);
        LAUNCHERROR("kCalculateSparseRawL1Error_kernel");
        blocks                      = CalculateBlocks(batch * getGpu()._warpSize);
        kCalculateSparseNonZeroL1Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
        LAUNCHERROR("kCalculateSparseNonZeroL1Error_kernel");
    }
    getGpu()._pbAccumulator->Download(); 
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseNonZeroL1Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            error              += w * (fabsf(a - (NNFloat)1.0) - fabsf(a));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseOnlyNonZeroL1Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            error              += w * fabsf(a - (NNFloat)1.0);   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

NNFloat kCalculateIndexedSparseL1Error(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight, bool bSparseIgnoreZero)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    if (bSparseIgnoreZero)
    {
        uint32_t blocks             = CalculateBlocks(batch * getGpu()._warpSize);    
        kCalculateIndexedSparseOnlyNonZeroL1Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pIndex, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
        LAUNCHERROR("kCalculateIndexedSparseOnlyNonZeroL1Error_kernel");    
    }
    else
    {
        uint64_t size               = (uint64_t)batch * (uint64_t)stride;
        uint32_t blocks             = CalculateBlocks(size);    
        kCalculateSparseRawL1Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, pSparseWeight, pUnit, stride, size);
        LAUNCHERROR("kCalculateSparseRawL1Error_kernel");
        blocks                      = CalculateBlocks(batch * getGpu()._warpSize);
        kCalculateIndexedSparseNonZeroL1Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pIndex, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
        LAUNCHERROR("kCalculateIndexedSparseNonZeroL1Error_kernel");
    }
    getGpu()._pbAccumulator->Download(); 
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseAnalogOnlyNonZeroL1Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, T* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            T t                 = pSparseData[pos1];
            error              += w * fabsf(a - t);   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseAnalogNonZeroL1Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, T* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            T t                 = pSparseData[pos1];
            error              += w * (fabsf(a - t) - fabsf(a));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}


template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseAnalogOnlyNonZeroL1Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, unsigned char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 256.0);
            error              += w * fabsf(a - t);   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}


template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseAnalogNonZeroL1Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, unsigned char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 256.0);
            error              += w * (fabsf(a - t) - fabsf(a));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseAnalogOnlyNonZeroL1Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 128.0);
            error              += w * fabsf(a - t);   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseAnalogNonZeroL1Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 128.0);
            error              += w * (fabsf(a - t) - fabsf(a));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<typename T>
NNFloat kCalculateSparseAnalogL1Error(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight, T* pSparseData, bool bSparseIgnoreZero)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    if (bSparseIgnoreZero)
    {
        uint32_t blocks         = CalculateBlocks(batch * getGpu()._warpSize);    
        kCalculateSparseAnalogOnlyNonZeroL1Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight, pSparseData);
        LAUNCHERROR("kCalculateSparseAnalogOnlyNonZeroL1Error_kernel");   
    }
    else
    {
        uint64_t size           = (uint64_t)batch * (uint64_t)stride;
        uint32_t blocks         = CalculateBlocks(size);    
        kCalculateSparseRawL1Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, pSparseWeight, pUnit, stride, size);
        LAUNCHERROR("kCalculateSparseRawL1Error_kernel");
        blocks                  = CalculateBlocks(batch * getGpu()._warpSize);
        kCalculateSparseAnalogNonZeroL1Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight, pSparseData);
        LAUNCHERROR("kCalculateSparseAnalogNonZeroL1Error_kernel");
    }
    getGpu()._pbAccumulator->Download(); 
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseAnalogOnlyNonZeroL1Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, T* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            T t                 = pSparseData[pos1];
            error              += w * fabsf(a - t);   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseAnalogNonZeroL1Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, T* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            T t                 = pSparseData[pos1];
            error              += w * (fabsf(a - t) - fabsf(a));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseAnalogOnlyNonZeroL1Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, unsigned char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 256.0);
            error              += w * fabsf(a - t);   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}


template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseAnalogNonZeroL1Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, unsigned char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 256.0);
            error              += w * (fabsf(a - t) - fabsf(a));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseAnalogOnlyNonZeroL1Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 128.0);
            error              += w * fabsf(a - t);   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseAnalogNonZeroL1Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 128.0);
            error              += w * (fabsf(a - t) - fabsf(a));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<typename T>
NNFloat kCalculateIndexedSparseAnalogL1Error(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight, T* pSparseData, bool bSparseIgnoreZero)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    if (bSparseIgnoreZero)
    {
        uint32_t blocks         = CalculateBlocks(batch * getGpu()._warpSize);    
        kCalculateIndexedSparseAnalogOnlyNonZeroL1Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pIndex, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight, pSparseData);
        LAUNCHERROR("kCalculateSparseAnalogOnlyNonZeroL1Error_kernel");   
    }
    else
    {
        uint64_t size           = (uint64_t)batch * (uint64_t)stride;
        uint32_t blocks         = CalculateBlocks(size);    
        kCalculateSparseRawL1Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, pSparseWeight, pUnit, stride, size);
        LAUNCHERROR("kCalculateSparseRawL1Error_kernel");
        blocks                  = CalculateBlocks(batch * getGpu()._warpSize);
        kCalculateIndexedSparseAnalogNonZeroL1Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pIndex, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight, pSparseData);
        LAUNCHERROR("kCalculateIndexedSparseAnalogNonZeroL1Error_kernel");
    }
    getGpu()._pbAccumulator->Download(); 
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

__global__ void
LAUNCH_BOUNDS()
kCalculateSparseRawL2Error_kernel(uint32_t position, NNFloat* pSparseWeight, NNFloat* pUnit, uint32_t stride, uint64_t size)
{
    uint64_t pos                = blockDim.x * blockIdx.x + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < size)
    {
        NNFloat w               = (NNFloat)0.5;
        if (pSparseWeight != NULL)
        {
            uint64_t dpos       = (pos / stride) + position;
            dpos                = cData._bShuffleIndices ? cData._pShuffleIndex[dpos] : dpos;
            w                  *= pSparseWeight[dpos];
        }
        NNFloat a               = pUnit[pos];
        error                   = w * a * a;     
    }
    
    REDUCEERROR(error)
}

__global__ void
LAUNCH_BOUNDS()
kCalculateSparseOnlyNonZeroL2Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (NNFloat)0.5 * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            error              += w * ((a - (NNFloat)1.0) * (a - (NNFloat)1.0));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

__global__ void
LAUNCH_BOUNDS()
kCalculateSparseNonZeroL2Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (NNFloat)0.5 * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            error              += w * ((a - (NNFloat)1.0) * (a - (NNFloat)1.0) - a * a);   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}


NNFloat kCalculateSparseL2Error(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight, bool bSparseIgnoreZero)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    if (bSparseIgnoreZero)
    {
        uint32_t blocks         = CalculateBlocks(batch * getGpu()._warpSize);    
        kCalculateSparseOnlyNonZeroL2Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
        LAUNCHERROR("kCalculateSparseOnlyNonZeroL2Error_kernel");    
    }
    else
    {
        uint64_t size           = batch * stride;
        uint32_t blocks         = CalculateBlocks(size);    
        kCalculateSparseRawL2Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, pSparseWeight, pUnit, stride, size);
        LAUNCHERROR("kCalculateSparseRawL2Error_kernel");
        blocks                  = CalculateBlocks(batch * getGpu()._warpSize);
        kCalculateSparseNonZeroL2Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
        LAUNCHERROR("kCalculateSparseNonZeroL2Error_kernel");
    }
    getGpu()._pbAccumulator->Download(); 
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseAnalogOnlyNonZeroL2Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, T* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (NNFloat)0.5 * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            T t                 = pSparseData[pos1];
            error              += w * ((a - t) * (a - t));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseAnalogNonZeroL2Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, T* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (NNFloat)0.5 * (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            T t                 = pSparseData[pos1];
            error              += w * ((a - t) * (a - t) - a * a);   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseAnalogOnlyNonZeroL2Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, unsigned char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (NNFloat)0.5 * (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 256.0);
            error              += w * ((a - t) * (a - t));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseAnalogNonZeroL2Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, unsigned char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (NNFloat)0.5 * (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 256.0);
            error              += w * ((a - t) * (a - t) - a * a);   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseAnalogOnlyNonZeroL2Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (NNFloat)0.5 * (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 128.0);
            error              += w * ((a - t) * (a - t));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseAnalogNonZeroL2Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (NNFloat)0.5 * (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 128.0);
            error              += w * ((a - t) * (a - t) - a * a);   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}


template<typename T>
NNFloat kCalculateSparseAnalogL2Error(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight, T* pSparseData, bool bSparseIgnoreZero)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    if (bSparseIgnoreZero)
    {
        uint32_t blocks         = CalculateBlocks(batch * getGpu()._warpSize);
        kCalculateSparseAnalogOnlyNonZeroL2Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight, pSparseData);
        LAUNCHERROR("kCalculateSparseAnalogOnlyNonZeroL2Error_kernel");    
    }
    else
    {
        uint64_t size           = batch * stride;
        uint32_t blocks         = CalculateBlocks(size);    
        kCalculateSparseRawL2Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, pSparseWeight, pUnit, stride, size);
        LAUNCHERROR("kCalculateSparseRawL2Error_kernel");
        blocks                  = CalculateBlocks(batch * getGpu()._warpSize);
        kCalculateSparseAnalogNonZeroL2Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight, pSparseData);
        LAUNCHERROR("kCalculateSparseAnalogNonZeroL2Error_kernel");
    }
    getGpu()._pbAccumulator->Download(); 
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseOnlyNonZeroL2Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (NNFloat)0.5 * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            error              += w * ((a - (NNFloat)1.0) * (a - (NNFloat)1.0));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseNonZeroL2Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (NNFloat)0.5 * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            error              += w * ((a - (NNFloat)1.0) * (a - (NNFloat)1.0) - a * a);   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}


NNFloat kCalculateIndexedSparseL2Error(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight, bool bSparseIgnoreZero)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    if (bSparseIgnoreZero)
    {
        uint32_t blocks         = CalculateBlocks(batch * getGpu()._warpSize);    
        kCalculateIndexedSparseOnlyNonZeroL2Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pIndex, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
        LAUNCHERROR("kCalculateIndexedSparseOnlyNonZeroL2Error_kernel");    
    }
    else
    {
        uint64_t size           = batch * stride;
        uint32_t blocks         = CalculateBlocks(size);    
        kCalculateSparseRawL2Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, pSparseWeight, pUnit, stride, size);
        LAUNCHERROR("kCalculateSparseRawL2Error_kernel");
        blocks                  = CalculateBlocks(batch * getGpu()._warpSize);
        kCalculateIndexedSparseNonZeroL2Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pIndex, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
        LAUNCHERROR("kCalculateIndexedSparseNonZeroL2Error_kernel");
    }
    getGpu()._pbAccumulator->Download(); 
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseAnalogOnlyNonZeroL2Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, T* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (NNFloat)0.5 * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            T t                 = pSparseData[pos1];
            error              += w * ((a - t) * (a - t));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseAnalogNonZeroL2Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, T* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (NNFloat)0.5 * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            T t                 = pSparseData[pos1];
            error              += w * ((a - t) * (a - t) - a * a);   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseAnalogOnlyNonZeroL2Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, unsigned char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (NNFloat)0.5 * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 256.0);
            error              += w * ((a - t) * (a - t));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseAnalogNonZeroL2Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, unsigned char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (NNFloat)0.5 * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 256.0);
            error              += w * ((a - t) * (a - t) - a * a);   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseAnalogOnlyNonZeroL2Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (NNFloat)0.5 * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 128.0);
            error              += w * ((a - t) * (a - t));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseAnalogNonZeroL2Error_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (NNFloat)0.5 * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 128.0);
            error              += w * ((a - t) * (a - t) - a * a);   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}


template<typename T>
NNFloat kCalculateIndexedSparseAnalogL2Error(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight, T* pSparseData, bool bSparseIgnoreZero)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    if (bSparseIgnoreZero)
    {
        uint32_t blocks         = CalculateBlocks(batch * getGpu()._warpSize);
        kCalculateIndexedSparseAnalogOnlyNonZeroL2Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pIndex, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight, pSparseData);
        LAUNCHERROR("kCalculateIndexedSparseAnalogOnlyNonZeroL2Error_kernel");    
    }
    else
    {
        uint64_t size           = batch * stride;
        uint32_t blocks         = CalculateBlocks(size);    
        kCalculateSparseRawL2Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, pSparseWeight, pUnit, stride, size);
        LAUNCHERROR("kCalculateSparseRawL2Error_kernel");
        blocks                  = CalculateBlocks(batch * getGpu()._warpSize);
        kCalculateIndexedSparseAnalogNonZeroL2Error_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pIndex, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight, pSparseData);
        LAUNCHERROR("kCalculateIndexedSparseAnalogNonZeroL2Error_kernel");
    }
    getGpu()._pbAccumulator->Download(); 
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

__global__ void
LAUNCH_BOUNDS()
kCalculateSparseRawCrossEntropyError_kernel(uint32_t position, NNFloat* pSparseWeight, NNFloat* pUnit, uint32_t stride, uint64_t size)
{
    uint64_t pos                = blockDim.x * blockIdx.x + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < size)
    {
        NNFloat w               = (NNFloat)1.0;
        if (pSparseWeight != NULL)
        {
            uint64_t dpos       = (pos / stride) + position;
            dpos                = cData._bShuffleIndices ? cData._pShuffleIndex[dpos] : dpos;
            w                  *= pSparseWeight[dpos];
        }
        NNFloat a               = pUnit[pos];
        error                   = -w * log(max(MIN_ERROR, (NNFloat)1.0 - a));     
    }

    REDUCEERROR(error)
}

__global__ void
LAUNCH_BOUNDS()
kCalculateSparseOnlyNonZeroCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            error              += -w * log(max(MIN_ERROR, a));   
            pos1               += cData._warpSize;
        }
    }  

/* LOOPY
            while (pos1 < end)
            {
                uint64_t pos2       = offset + pSparseIndex[pos1];
                NNFloat a           = pUnit[pos2];
                error              += -t * log(max(MIN_ERROR, a)) - ((NNFloat)1.0 - t) * log(max(MIN_ERROR, (NNFloat)1.0 - a));   
                pos1               += cData._warpSize;
            }
*/

    REDUCEERROR(error)
}

__global__ void
LAUNCH_BOUNDS()
kCalculateSparseNonZeroCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            error              += w * (-log(max(MIN_ERROR, a)) + log(max(MIN_ERROR, (NNFloat)1.0 - a)));   
            pos1               += cData._warpSize;
        }
/* LOOPY
            while (pos1 < end)
            {
                uint64_t pos2       = offset + pSparseIndex[pos1];
                NNFloat a           = pUnit[pos2];
                error              += -t * log(max(MIN_ERROR, a)) + t * log(max(MIN_ERROR, (NNFloat)1.0 - a)); // -t * log(a) - (1.0 - t) * log(1.0 - a) + log(1.0 - a)  
                pos1               += cData._warpSize;
            }
*/
    }  

    REDUCEERROR(error)
}

NNFloat kCalculateSparseCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight, bool bSparseIgnoreZero)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    if (bSparseIgnoreZero)
    {
        uint32_t blocks         = CalculateBlocks(batch * getGpu()._warpSize);
        kCalculateSparseOnlyNonZeroCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
        LAUNCHERROR("kCalculateSparseOnlyNonZeroCrossEntropyError_kernel");    
    }
    else
    {    
        uint64_t size           = (uint64_t)batch * (uint64_t)stride;
        uint32_t blocks         = CalculateBlocks(size);
        kCalculateSparseRawCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, pSparseWeight, pUnit, stride, size);
        LAUNCHERROR("kCalculateSparseRawCrossEntropyError_kernel");
        blocks                  = CalculateBlocks(batch * getGpu()._warpSize);
        kCalculateSparseNonZeroCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
        LAUNCHERROR("kCalculateSparseNonZeroCrossEntropyError_kernel");
    }
    getGpu()._pbAccumulator->Download(); 
    //printf("Error is %f\n",  (double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);

    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseOnlyNonZeroCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            error              += -w * log(max(MIN_ERROR, a));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseNonZeroCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{
    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            error              += w * (-log(max(MIN_ERROR, a)) + log(max(MIN_ERROR, (NNFloat)1.0 - a)));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

NNFloat kCalculateIndexedSparseCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight, bool bSparseIgnoreZero)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    if (bSparseIgnoreZero)
    {
        uint32_t blocks         = CalculateBlocks(batch * getGpu()._warpSize);
        kCalculateIndexedSparseOnlyNonZeroCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pIndex, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
        LAUNCHERROR("kCalculateSparseOnlyNonZeroCrossEntropyError_kernel");    
    }
    else
    {    
        uint64_t size           = (uint64_t)batch * (uint64_t)stride;
        uint32_t blocks         = CalculateBlocks(size);
        kCalculateSparseRawCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, pSparseWeight, pUnit, stride, size);
        LAUNCHERROR("kCalculateSparseRawCrossEntropyError_kernel");
        blocks                  = CalculateBlocks(batch * getGpu()._warpSize);
        kCalculateIndexedSparseNonZeroCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pIndex, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
        LAUNCHERROR("kCalculateIndexedSparseNonZeroCrossEntropyError_kernel");
    }
    getGpu()._pbAccumulator->Download(); 
    //printf("Error is %f\n",  (double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);

    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

__global__ void
LAUNCH_BOUNDS()
kCalculateSparseMultinomialCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos];
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight == NULL) ? (NNFloat)1.0 / (NNFloat)(end - pos1) : pSparseWeight[dpos];
        pos1                   += threadIdx.x & cData._warpMask;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            error              += -w * log(max(MIN_ERROR, a));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

NNFloat kCalculateSparseMultinomialCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    uint32_t blocks             = CalculateBlocks(batch * getGpu()._warpSize);
    kCalculateSparseMultinomialCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
    LAUNCHERROR("kCalculateSparseMultinomialCrossEntropyError_kernel");
    getGpu()._pbAccumulator->Download(); 
    //printf("Error is %f\n",  (double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);

    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseMultinomialCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos];
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight == NULL) ? (NNFloat)1.0 / (NNFloat)(end - pos1) : pSparseWeight[dpos];
        pos1                   += threadIdx.x & cData._warpMask;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            error              += -w * log(max(MIN_ERROR, a));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

NNFloat kCalculateIndexedSparseMultinomialCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    uint32_t blocks             = CalculateBlocks(batch * getGpu()._warpSize);
    kCalculateIndexedSparseMultinomialCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pIndex, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
    LAUNCHERROR("kCalculateIndexedSparseMultinomialCrossEntropyError_kernel");
    getGpu()._pbAccumulator->Download(); 
    //printf("Error is %f\n",  (double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);

    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseAnalogMultinomialCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, T* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            T t                 = pSparseData[pos1];
            error              += w * (-t * log(max(MIN_ERROR, a)));
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseAnalogMultinomialCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, unsigned char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 256.0);
            error              += w * (-t * log(max(MIN_ERROR, a)));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseAnalogMultinomialCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 128.0);
            error              += w * (-t * log(max(MIN_ERROR, a)));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}


template<typename T>
NNFloat kCalculateSparseAnalogMultinomialCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight, T* pSparseData)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    uint32_t blocks             = CalculateBlocks(batch * getGpu()._warpSize);
    kCalculateSparseAnalogMultinomialCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight, pSparseData);
    LAUNCHERROR("kCalculateSparseAnalogMultinomialCrossEntropyError_kernel");
    getGpu()._pbAccumulator->Download(); 
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseAnalogMultinomialCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, T* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            T t                 = pSparseData[pos1];
            error              += w * (-t * log(max(MIN_ERROR, a)));
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseAnalogMultinomialCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, unsigned char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 256.0);
            error              += w * (-t * log(max(MIN_ERROR, a)));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseAnalogMultinomialCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, char* pSparseData)
{

    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = (NNFloat)pSparseData[pos1] * (NNFloat)(1.0 / 128.0);
            error              += w * (-t * log(max(MIN_ERROR, a)));   
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}


template<typename T>
NNFloat kCalculateIndexedSparseAnalogMultinomialCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight, T* pSparseData)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    uint32_t blocks             = CalculateBlocks(batch * getGpu()._warpSize);
    kCalculateIndexedSparseAnalogMultinomialCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pIndex, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight, pSparseData);
    LAUNCHERROR("kCalculateIndexedSparseAnalogMultinomialCrossEntropyError_kernel");
    getGpu()._pbAccumulator->Download(); 
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

__global__ void
LAUNCH_BOUNDS()
kCalculateSparseRawScaledMarginalCrossEntropyError_kernel(uint32_t position, NNFloat* pSparseWeight, NNFloat* pUnit, uint32_t stride, uint64_t size)
{
    uint64_t pos                = blockDim.x * blockIdx.x + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < size)
    {
        NNFloat w               = cData._SMCE_zeroScale;
        if (pSparseWeight != NULL)
        {
            uint64_t dpos       = pos / stride;
            dpos                = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
            w                  *= pSparseWeight[dpos];
        }
        NNFloat a               = pUnit[pos];
        if (a > cData._SMCE_zeroTarget)
            error               = -w * log(max(MIN_ERROR, (NNFloat)1.0 - a));     
    }
    
    REDUCEERROR(error)
}

__global__ void
LAUNCH_BOUNDS()
kCalculateSparseOnlyNonZeroScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{
    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = cData._SMCE_oneScale * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            if (a < cData._SMCE_oneTarget)
                error          += -w * log(max(MIN_ERROR, a));
            pos1               += cData._warpSize;
        }
/* LOOPY
        }
        else
        {
            while (pos1 < end)
            {
                uint64_t pos2       = offset + pSparseIndex[pos1];
                NNFloat a           = pUnit[pos2];
                if (a < cData._SMCE_oneTarget)
                   error           += cData._SMCE_oneScale * (-t * log(max(MIN_ERROR, a)) - ((NNFloat)1.0 - t) * log(max(MIN_ERROR, (NNFloat)1.0 - a)));   
                pos1               += cData._warpSize;
            }
        }
*/
    }  

    REDUCEERROR(error)
}

__global__ void
LAUNCH_BOUNDS()
kCalculateSparseNonZeroScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{
    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            if (a > cData._SMCE_zeroTarget)
            {
                error          += w * cData._SMCE_zeroScale * log(max(MIN_ERROR, (NNFloat)1.0 - a));
            }
            if (a < cData._SMCE_oneTarget)
            {
                error          += -w * cData._SMCE_oneScale * log(max(MIN_ERROR, a));
            }
            pos1               += cData._warpSize;
        }


/* LOOPY
        }
        else
        {
            while (pos1 < end)
            {
                uint64_t pos2       = offset + pSparseIndex[pos1];
                NNFloat a           = pUnit[pos2];
                if (a > cData._SMCE_zeroTarget)
                {
                    error          += cData._SMCE_zeroScale * log(max(MIN_ERROR, (NNFloat)1.0 - a));
                }
                if (a < cData._SMCE_oneTarget)
                {
                    error          += cData._SMCE_oneScale * (-t * log(max(MIN_ERROR, a)) - ((NNFloat)1.0 - t) * log(max(MIN_ERROR, (NNFloat)1.0 - a)));
                }
                pos1               += cData._warpSize;
            }
        }
*/
    }  

    REDUCEERROR(error)
}

NNFloat kCalculateSparseScaledMarginalCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight, bool bSparseIgnoreZero)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    if (bSparseIgnoreZero)
    {
        uint32_t blocks         = CalculateBlocks(batch * getGpu()._warpSize);
        kCalculateSparseOnlyNonZeroScaledMarginalCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
        LAUNCHERROR("kCalculateSparseOnlyNonZeroScaledMarginalCrossEntropyError_kernel");   
    }
    else
    {
        uint64_t size           = (uint64_t)batch * (uint64_t)stride;
        uint32_t blocks         = CalculateBlocks(size);
        kCalculateSparseRawScaledMarginalCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, pSparseWeight, pUnit, stride, size);
        LAUNCHERROR("kCalculateSparseRawScaledMarginalCrossEntropyError_kernel");
        blocks                  = CalculateBlocks(batch * getGpu()._warpSize);
        kCalculateSparseNonZeroScaledMarginalCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
        LAUNCHERROR("kCalculateSparseNonZeroScaledMarginalCrossEntropyError_kernel");
    }    
    getGpu()._pbAccumulator->Download(); 
    //printf("Error is %f\n",  (double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseOnlyNonZeroScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{
    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = cData._SMCE_oneScale * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            if (a < cData._SMCE_oneTarget)
                error          += -w * log(max(MIN_ERROR, a));
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseNonZeroScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{
    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = (pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            if (a > cData._SMCE_zeroTarget)
            {
                error          += w * cData._SMCE_zeroScale * log(max(MIN_ERROR, (NNFloat)1.0 - a));
            }
            if (a < cData._SMCE_oneTarget)
            {
                error          += -w * cData._SMCE_oneScale * log(max(MIN_ERROR, a));
            }
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

NNFloat kCalculateIndexedSparseScaledMarginalCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight, bool bSparseIgnoreZero)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    if (bSparseIgnoreZero)
    {
        uint32_t blocks         = CalculateBlocks(batch * getGpu()._warpSize);
        kCalculateIndexedSparseOnlyNonZeroScaledMarginalCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pIndex, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
        LAUNCHERROR("kCalculateSparseOnlyNonZeroScaledMarginalCrossEntropyError_kernel");   
    }
    else
    {
        uint64_t size           = (uint64_t)batch * (uint64_t)stride;
        uint32_t blocks         = CalculateBlocks(size);
        kCalculateSparseRawScaledMarginalCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, pSparseWeight, pUnit, stride, size);
        LAUNCHERROR("kCalculateSparseRawScaledMarginalCrossEntropyError_kernel");
        blocks                  = CalculateBlocks(batch * getGpu()._warpSize);
        kCalculateIndexedSparseNonZeroScaledMarginalCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pIndex, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
        LAUNCHERROR("kCalculateIndexedSparseNonZeroScaledMarginalCrossEntropyError_kernel");
    }    
    getGpu()._pbAccumulator->Download(); 
    //printf("Error is %f\n",  (double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

__global__ void
LAUNCH_BOUNDS()
kCalculateSparseRawDataScaledMarginalCrossEntropyError_kernel(NNFloat* pUnit, uint64_t size)
{
    uint64_t pos                = blockDim.x * blockIdx.x + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < size)
    {
          NNFloat a               = pUnit[pos];
          if (a > cData._SMCE_zeroTarget)
          {
              error               = -cData._SMCE_zeroScale * log(max(MIN_ERROR, (NNFloat)1.0 - a));
          }
    }

    REDUCEERROR(error)
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseNonZeroDataScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, T* pSparseData)
{
    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
              uint64_t pos2       = offset + pSparseIndex[pos1];
              NNFloat a           = pUnit[pos2];
              T t                 = pSparseData[pos1];

              if (a > cData._SMCE_zeroTarget)
              {
                  error          += cData._SMCE_zeroScale * log(max(MIN_ERROR, (NNFloat)1.0 - a));
              }

              if (a < cData._SMCE_oneTarget)
              {
                  error          += -cData._SMCE_oneScale * t * log(max(MIN_ERROR, a));
              }
              pos1               += cData._warpSize;
        }
    }

    REDUCEERROR(error)
}

template<typename T>
NNFloat kCalculateSparseDataScaledMarginalCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, T* pSparseData, bool bSparseIgnoreZero)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));

    if (!bSparseIgnoreZero)
    {
        uint64_t size               = (uint64_t)batch * (uint64_t)stride;
        uint32_t blocks             = CalculateBlocks(size);
        kCalculateSparseRawDataScaledMarginalCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(pUnit, size);
        LAUNCHERROR("kCalculateSparseRawDataScaledMarginalCrossEntropyError_kernel");
    }
    uint32_t blocks             = CalculateBlocks(batch * getGpu()._warpSize);
    kCalculateSparseNonZeroDataScaledMarginalCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pSparseStart, pSparseEnd, pSparseIndex, pSparseData);
    LAUNCHERROR("kCalculateSparseNonZeroDataScaledMarginalCrossEntropyError_kernel");
    getGpu()._pbAccumulator->Download();
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}



template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseNonZeroDataScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, T* pSparseData)
{
    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
              uint64_t pos2       = offset + pSparseIndex[pos1];
              NNFloat a           = pUnit[pos2];
              T t                 = pSparseData[pos1];

              if (a > cData._SMCE_zeroTarget)
              {
                  error          += cData._SMCE_zeroScale * log(max(MIN_ERROR, (NNFloat)1.0 - a));
              }

              if (a < cData._SMCE_oneTarget)
              {
                  error          += -cData._SMCE_oneScale * t * log(max(MIN_ERROR, a));
              }
              pos1               += cData._warpSize;
        }
    }

    REDUCEERROR(error)
}

template<typename T>
NNFloat kCalculateIndexedSparseDataScaledMarginalCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, T* pSparseData, bool bSparseIgnoreZero)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));

    if (!bSparseIgnoreZero)
    {
        uint64_t size               = (uint64_t)batch * (uint64_t)stride;
        uint32_t blocks             = CalculateBlocks(size);
        kCalculateSparseRawDataScaledMarginalCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(pUnit, size);
        LAUNCHERROR("kCalculateSparseRawDataScaledMarginalCrossEntropyError_kernel");
    }
    uint32_t blocks             = CalculateBlocks(batch * getGpu()._warpSize);
    kCalculateIndexedSparseNonZeroDataScaledMarginalCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pIndex, pSparseStart, pSparseEnd, pSparseIndex, pSparseData);
    LAUNCHERROR("kCalculateIndexedSparseNonZeroDataScaledMarginalCrossEntropyError_kernel");
    getGpu()._pbAccumulator->Download();
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

__global__ void
LAUNCH_BOUNDS()
kCalculateSparseMultinomialScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{
    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos];
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = cData._SMCE_oneScale * ((pSparseWeight == NULL) ? (NNFloat)1.0 / (NNFloat)(end - pos1) : pSparseWeight[dpos]);
        pos1                   += threadIdx.x & cData._warpMask;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2]; 
            if (a < cData._SMCE_oneTarget)
                error          += -w * log(max(MIN_ERROR, a));
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

NNFloat kCalculateSparseMultinomialScaledMarginalCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    uint32_t blocks             = CalculateBlocks(batch * getGpu()._warpSize);
    kCalculateSparseNonZeroScaledMarginalCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
    LAUNCHERROR("kCalculateSparseMultinomialScaledMarginalCrossEntropyError_kernel");    
    getGpu()._pbAccumulator->Download(); 
    //printf("Error is %f\n",  (double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseMultinomialScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight)
{
    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos];
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = cData._SMCE_oneScale * ((pSparseWeight == NULL) ? (NNFloat)1.0 / (NNFloat)(end - pos1) : pSparseWeight[dpos]);
        pos1                   += threadIdx.x & cData._warpMask;
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2]; 
            if (a < cData._SMCE_oneTarget)
                error          += -w * log(max(MIN_ERROR, a));
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

NNFloat kCalculateIndexedSparseMultinomialScaledMarginalCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    uint32_t blocks             = CalculateBlocks(batch * getGpu()._warpSize);
    kCalculateIndexedSparseNonZeroScaledMarginalCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pIndex, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight);
    LAUNCHERROR("kCalculateIndexedSparseMultinomialScaledMarginalCrossEntropyError_kernel");    
    getGpu()._pbAccumulator->Download(); 
    //printf("Error is %f\n",  (double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}




template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseAnalogMultinomialScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, T* pSparseData)
{
    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = cData._SMCE_oneScale * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            T t                 = pSparseData[pos1];  
            if (a < cData._SMCE_oneTarget)
                error          += -w * t * log(max(MIN_ERROR, a));
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseAnalogMultinomialScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, unsigned char* pSparseData)
{
    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = cData._SMCE_oneScale * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = pSparseData[pos1] * (NNFloat)(1.0 / 256.0);
            if (a < cData._SMCE_oneTarget)
                error          += -w * t * log(max(MIN_ERROR, a));
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateSparseAnalogMultinomialScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, char* pSparseData)
{
    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos;
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = cData._SMCE_oneScale * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = pSparseData[pos1] * (NNFloat)(1.0 / 128.0);
            if (a < cData._SMCE_oneTarget)
                error          += -w * t * log(max(MIN_ERROR, a));
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<typename T>
NNFloat kCalculateSparseAnalogMultinomialScaledMarginalCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight, T* pSparseData)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    uint32_t blocks             = CalculateBlocks(batch * getGpu()._warpSize);
    kCalculateSparseAnalogMultinomialScaledMarginalCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight, pSparseData);
    LAUNCHERROR("kCalculateSparseAnalogMultinomialScaledMarginalCrossEntropyError_kernel");    
    getGpu()._pbAccumulator->Download(); 
    //printf("Error is %f\n",  (double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}


template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseAnalogMultinomialScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, T* pSparseData)
{
    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = cData._SMCE_oneScale * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            T t                 = pSparseData[pos1];  
            if (a < cData._SMCE_oneTarget)
                error          += -w * t * log(max(MIN_ERROR, a));
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseAnalogMultinomialScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, unsigned char* pSparseData)
{
    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = cData._SMCE_oneScale * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = pSparseData[pos1] * (NNFloat)(1.0 / 256.0);
            if (a < cData._SMCE_oneTarget)
                error          += -w * t * log(max(MIN_ERROR, a));
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedSparseAnalogMultinomialScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t batch, uint32_t stride, NNFloat *pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t* pSparseEnd, uint32_t* pSparseIndex, NNFloat* pSparseWeight, char* pSparseData)
{
    uint64_t pos                = (blockIdx.x * blockDim.x + threadIdx.x) / cData._warpSize;
    NNFloat error               = (NNFloat)0.0;
    if (pos < batch)
    {
        uint32_t dpos           = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + pos] : position + pos];
        uint64_t pos1           = pSparseStart[dpos] + (threadIdx.x & cData._warpMask);
        uint64_t end            = pSparseEnd[dpos];
        NNFloat w               = cData._SMCE_oneScale * ((pSparseWeight != NULL) ? pSparseWeight[dpos] : (NNFloat)1.0);
        uint64_t offset         = pos * stride;
        while (pos1 < end)
        {
            uint64_t pos2       = offset + pSparseIndex[pos1];
            NNFloat a           = pUnit[pos2];
            NNFloat t           = pSparseData[pos1] * (NNFloat)(1.0 / 128.0);
            if (a < cData._SMCE_oneTarget)
                error          += -w * t * log(max(MIN_ERROR, a));
            pos1               += cData._warpSize;
        }
    }  

    REDUCEERROR(error)
}

template<typename T>
NNFloat kCalculateIndexedSparseAnalogMultinomialScaledMarginalCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, uint64_t* pSparseStart, uint64_t *pSparseEnd, uint32_t *pSparseIndex, NNFloat* pSparseWeight, T* pSparseData)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    uint32_t blocks             = CalculateBlocks(batch * getGpu()._warpSize);
    kCalculateIndexedSparseAnalogMultinomialScaledMarginalCrossEntropyError_kernel<<<blocks, getGpu()._threadsPerBlock>>>(position, batch, stride, pUnit, pIndex, pSparseStart, pSparseEnd, pSparseIndex, pSparseWeight, pSparseData);
    LAUNCHERROR("kCalculateIndexedSparseAnalogMultinomialScaledMarginalCrossEntropyError_kernel");    
    getGpu()._pbAccumulator->Download(); 
    //printf("Error is %f\n",  (double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateL1Error_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, T* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = (cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x) * stride;
        NNFloat a               = pUnit[uOffset + pos];
        T t                     = pData[dOffset + pos];
        error                   = fabsf(a - t);        
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateL1Error_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, unsigned char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = (cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x) * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 256.0);
        error                   = fabsf(a - t);        
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateL1Error_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = (cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x) * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 128.0);
        error                   = fabsf(a - t);        
    }

    REDUCEERROR(error)
}

template<typename T> NNFloat kCalculateL1Error(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, T* pData)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    dim3 grid(batch, (stride + getGpu()._threadsPerBlock - 1) / getGpu()._threadsPerBlock);
    kCalculateL1Error_kernel<<<grid, getGpu()._threadsPerBlock>>>(position, stride, pUnit, pData);
    LAUNCHERROR("kCalculateL1Error_kernel");
    getGpu()._pbAccumulator->Download();
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedL1Error_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, T* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;
        NNFloat a               = pUnit[uOffset + pos];
        T t                     = pData[dOffset + pos];
        error                   = fabsf(a - t);        
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedL1Error_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, unsigned char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 256.0);
        error                   = fabsf(a - t);        
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedL1Error_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 128.0);
        error                   = fabsf(a - t);        
    }

    REDUCEERROR(error)
}

template<typename T> NNFloat kCalculateIndexedL1Error(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, T* pData)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    dim3 grid(batch, (stride + getGpu()._threadsPerBlock - 1) / getGpu()._threadsPerBlock);
    kCalculateIndexedL1Error_kernel<<<grid, getGpu()._threadsPerBlock>>>(position, stride, pUnit, pIndex, pData);
    LAUNCHERROR("kCalculateL1Error_kernel");
    getGpu()._pbAccumulator->Download();
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateL2Error_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, T* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = (cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x) * stride;
        NNFloat a               = pUnit[uOffset + pos];
        T t                     = pData[dOffset + pos];
        error                   = (NNFloat)0.5 * (a - t) * (a - t);         
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateL2Error_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, unsigned char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = (cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x) * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 256.0);
        error                   = (NNFloat)0.5 * (a - t) * (a - t);         

    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateL2Error_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = (cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x) * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 128.0);
        error                   = (NNFloat)0.5 * (a - t) * (a - t);         

    }

    REDUCEERROR(error)
}

template<typename T> NNFloat kCalculateL2Error(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, T* pData)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    dim3 grid(batch, (stride + getGpu()._threadsPerBlock - 1) / getGpu()._threadsPerBlock);
    kCalculateL2Error_kernel<<<grid, getGpu()._threadsPerBlock>>>(position, stride, pUnit, pData);
    LAUNCHERROR("kCalculateL2Error_kernel");    
    getGpu()._pbAccumulator->Download();
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE); 
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedL2Error_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, T* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;
        NNFloat a               = pUnit[uOffset + pos];
        T t                     = pData[dOffset + pos];
        error                   = (NNFloat)0.5 * (a - t) * (a - t);         
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedL2Error_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, unsigned char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 256.0);
        error                   = (NNFloat)0.5 * (a - t) * (a - t);         

    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedL2Error_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 128.0);
        error                   = (NNFloat)0.5 * (a - t) * (a - t);         

    }

    REDUCEERROR(error)
}

template<typename T> NNFloat kCalculateIndexedL2Error(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, T* pData)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    dim3 grid(batch, (stride + getGpu()._threadsPerBlock - 1) / getGpu()._threadsPerBlock);
    kCalculateIndexedL2Error_kernel<<<grid, getGpu()._threadsPerBlock>>>(position, stride, pUnit, pIndex, pData);
    LAUNCHERROR("kCalculateIndexedL2Error_kernel");    
    getGpu()._pbAccumulator->Download();
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE); 
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateHingeError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, T* pData)
{
    // Calculate initial offsets
    pUnit                      += blockIdx.x * stride;
    pData                      += cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x * stride;

    // Calculate loss
    uint32_t pos                = threadIdx.x;
    NNFloat loss                = (NNFloat)0.0;
    
    while (pos < stride)
    {
        NNFloat t               = pData[pos];
        NNFloat y               = pUnit[pos];
        loss                   += max((NNFloat)0.0, (NNFloat)1.0 - t * y);
        pos                    += blockDim.x;
        printf("HL %d %f %f %f\n", blockIdx.x, t, y, loss);
    }
    
    REDUCEERROR(loss)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateHingeError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, unsigned char* pData)
{ 
    // Calculate initial offsets
    pUnit                      += blockIdx.x * stride;
    pData                      += cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x * stride;

    // Calculate loss
    uint32_t pos                = threadIdx.x;
    NNFloat loss                = (NNFloat)0.0;
    
    while (pos < stride)
    {
        NNFloat t               = pData[pos] * (NNFloat)(1.0 / 128.0);
        NNFloat y               = pUnit[pos];
        loss                   += max((NNFloat)0.0, (NNFloat)1.0 - t * y);
        pos                    += blockDim.x;    
    }
    
    REDUCEERROR(loss)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateHingeError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, char* pData)
{

    // Calculate initial offsets
    pUnit                      += blockIdx.x * stride;
    pData                      += cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x * stride;

    // Calculate loss
    uint32_t pos                = threadIdx.x;
    NNFloat loss                = (NNFloat)0.0;
    
    while (pos < stride)
    {
        NNFloat t               = (NNFloat)pData[pos] * (NNFloat)(1.0 / 256.0);
        NNFloat y               = pUnit[pos];
        loss                   += max((NNFloat)0.0, (NNFloat)1.0 - t * y);
        pos                    += blockDim.x;    
    }
    
    REDUCEERROR(loss)
}

template<typename T> NNFloat kCalculateHingeError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, T* pData)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    unsigned long threads = max(32, min(stride, 128));
    kCalculateHingeError_kernel<<<batch, threads>>>(position, stride, pUnit, pData);
    LAUNCHERROR("kCalculateHingeError_kernel");    
    getGpu()._pbAccumulator->Download();
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE); 
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedHingeError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, T* pData)
{
    // Calculate initial offsets
    pUnit                      += blockIdx.x * stride;
    pData                      += pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;

    // Calculate loss
    uint32_t pos                = threadIdx.x;
    NNFloat loss                = (NNFloat)0.0;
    
    while (pos < stride)
    {
        NNFloat t               = pData[pos];
        NNFloat y               = pUnit[pos];
        loss                   += max((NNFloat)0.0, (NNFloat)1.0 - t * y);
        pos                    += blockDim.x;    
    }
    
    REDUCEERROR(loss)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedHingeError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, unsigned char* pData)
{ 
    // Calculate initial offsets
    pUnit                      += blockIdx.x * stride;
    pData                      += pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;

    // Calculate loss
    uint32_t pos                = threadIdx.x;
    NNFloat loss                = (NNFloat)0.0;
    
    while (pos < stride)
    {
        NNFloat t               = pData[pos] * (NNFloat)(1.0 / 256.0);
        NNFloat y               = pUnit[pos];
        loss                   += max((NNFloat)0.0, (NNFloat)1.0 - t * y);
        pos                    += blockDim.x;    
    }
    
    REDUCEERROR(loss)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedHingeError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, char* pData)
{

    // Calculate initial offsets
    pUnit                      += blockIdx.x * stride;
    pData                      += pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;

    // Calculate loss
    uint32_t pos                = threadIdx.x;
    NNFloat loss                = (NNFloat)0.0;
    
    while (pos < stride)
    {
        NNFloat t               = (NNFloat)pData[pos] * (NNFloat)(1.0 / 128.0);
        NNFloat y               = pUnit[pos];
        loss                   += max((NNFloat)0.0, (NNFloat)1.0 - t * y);
        pos                    += blockDim.x;    
    }
    
    REDUCEERROR(loss)
}

template<typename T> NNFloat kCalculateIndexedHingeError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, T* pData)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    unsigned long threads = max(32, min(stride, 128));
    kCalculateIndexedHingeError_kernel<<<batch, threads>>>(position, stride, pUnit, pIndex, pData);
    LAUNCHERROR("kCalculateIndexedHingeError_kernel");    
    getGpu()._pbAccumulator->Download();
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE); 
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, T* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = (cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x) * stride;
        NNFloat a               = pUnit[uOffset + pos];
        T t                     = pData[dOffset + pos];
        error                   = -t * log(max(MIN_ERROR, a)) - ( (NNFloat)1.0 - t) * log(max(MIN_ERROR, (NNFloat)1.0 - a));     
        //printf("%d %llu %f %f %f\n", position, pos, a, t, error);
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = (cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x) * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 128.0);
        error                   = -t * log(max(MIN_ERROR, a)) - ( (NNFloat)1.0 - t) * log(max(MIN_ERROR, (NNFloat)1.0 - a));     
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, unsigned char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = (cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x) * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 256.0);
        error                   = -t * log(max(MIN_ERROR, a)) - ( (NNFloat)1.0 - t) * log(max(MIN_ERROR, (NNFloat)1.0 - a));     
        //printf("%d %llu %f %f %f\n", position, pos, a, t, error);
    }

    REDUCEERROR(error)
}

template<typename T> NNFloat kCalculateCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, T* pData)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    dim3 grid(batch, (stride + getGpu()._threadsPerBlock - 1) / getGpu()._threadsPerBlock);
    kCalculateCrossEntropyError_kernel<<<grid, getGpu()._threadsPerBlock>>>(position, stride, pUnit, pData);
    LAUNCHERROR("kCalculateCrossEntropyError_kernel");
    getGpu()._pbAccumulator->Download();
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, T* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;
        NNFloat a               = pUnit[uOffset + pos];
        T t                     = pData[dOffset + pos];
        error                   = -t * log(max(MIN_ERROR, a)) - ( (NNFloat)1.0 - t) * log(max(MIN_ERROR, (NNFloat)1.0 - a));     
        //printf("%d %llu %f %f %f\n", position, pos, a, t, error);
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 128.0);
        error                   = -t * log(max(MIN_ERROR, a)) - ( (NNFloat)1.0 - t) * log(max(MIN_ERROR, (NNFloat)1.0 - a));     
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, unsigned char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 256.0);
        error                   = -t * log(max(MIN_ERROR, a)) - ( (NNFloat)1.0 - t) * log(max(MIN_ERROR, (NNFloat)1.0 - a));     
        //printf("%d %llu %f %f %f\n", position, pos, a, t, error);
    }

    REDUCEERROR(error)
}

template<typename T> NNFloat kCalculateIndexedCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, T* pData)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    dim3 grid(batch, (stride + getGpu()._threadsPerBlock - 1) / getGpu()._threadsPerBlock);
    kCalculateIndexedCrossEntropyError_kernel<<<grid, getGpu()._threadsPerBlock>>>(position, stride, pUnit, pIndex, pData);
    LAUNCHERROR("kCalculateIndexedCrossEntropyError_kernel");
    getGpu()._pbAccumulator->Download();
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateMultinomialCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, T* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = (cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x) * stride;
        NNFloat a               = pUnit[uOffset + pos];
        T t                     = pData[dOffset + pos];
        error                   = -t * log(max(MIN_ERROR, a));  
        //printf("%d %llu %f %f %f\n", position, pos, a, t, error);
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateMultinomialCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = (cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x) * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 128.0);
        error                   = -t * log(max(MIN_ERROR, a));     
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateMultinomialCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, unsigned char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = (cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x) * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 256.0);
        error                   = -t * log(max(MIN_ERROR, a));     
        //printf("%d %llu %f %f %f\n", position, pos, a, t, error);
    }

    REDUCEERROR(error)
}

template<typename T> NNFloat kCalculateMultinomialCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, T* pData)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    dim3 grid(batch, (stride + getGpu()._threadsPerBlock - 1) / getGpu()._threadsPerBlock);
    kCalculateMultinomialCrossEntropyError_kernel<<<grid, getGpu()._threadsPerBlock>>>(position, stride, pUnit, pData);
    LAUNCHERROR("kCalculateMultinomialCrossEntropyError_kernel");
    getGpu()._pbAccumulator->Download();
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}


template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedMultinomialCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, T* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;
        NNFloat a               = pUnit[uOffset + pos];
        T t                     = pData[dOffset + pos];
        error                   = -t * log(max(MIN_ERROR, a));  
        //printf("%d %llu %f %f %f\n", position, pos, a, t, error);
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedMultinomialCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 128.0);
        error                   = -t * log(max(MIN_ERROR, a));     
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedMultinomialCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, unsigned char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 256.0);
        error                   = -t * log(max(MIN_ERROR, a));     
        //printf("%d %llu %f %f %f\n", position, pos, a, t, error);
    }

    REDUCEERROR(error)
}

template<typename T> NNFloat kCalculateIndexedMultinomialCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, T* pData)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    dim3 grid(batch, (stride + getGpu()._threadsPerBlock - 1) / getGpu()._threadsPerBlock);
    kCalculateIndexedMultinomialCrossEntropyError_kernel<<<grid, getGpu()._threadsPerBlock>>>(position, stride, pUnit, pIndex, pData);
    LAUNCHERROR("kCalculateIndexedMultinomialCrossEntropyError_kernel");
    getGpu()._pbAccumulator->Download();
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

// HERE 2
template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, T* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = (cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x) * stride;
        NNFloat a               = pUnit[uOffset + pos];
        T t                     = pData[dOffset + pos];
        if (((t == (T)1.0) && (a < cData._SMCE_oneTarget)) || 
            ((t == (T)0.0) && (a > cData._SMCE_zeroTarget)))
            error               = -t * cData._SMCE_oneScale * log(max(MIN_ERROR, a)) - ( (NNFloat)1.0 - t) * cData._SMCE_zeroScale * log(max(MIN_ERROR, (NNFloat)1.0 - a));     
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = (cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x) * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 128.0);
        if (((t == (NNFloat)1.0) && (a < cData._SMCE_oneTarget)) || ((t == (NNFloat)0.0) && (a > cData._SMCE_zeroTarget)))
            error               = -t * cData._SMCE_oneScale * log(max(MIN_ERROR, a)) - ((NNFloat)1.0 - t) * cData._SMCE_zeroScale * log(max(MIN_ERROR, (NNFloat)1.0 - a));  
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, unsigned char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = (cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x) * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 256.0);
        if (((t == (NNFloat)1.0) && (a < cData._SMCE_oneTarget)) || ((t == (NNFloat)0.0) && (a > cData._SMCE_zeroTarget)))
            error               = -t * cData._SMCE_oneScale * log(max(MIN_ERROR, a)) - ((NNFloat)1.0 - t) * cData._SMCE_zeroScale * log(max(MIN_ERROR, (NNFloat)1.0 - a));  
        //printf("%d %llu %f %f %f\n", position, pos, a, t, error);
    }

    REDUCEERROR(error)
}

template<typename T> NNFloat kCalculateScaledMarginalCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, T* pData)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    dim3 grid(batch, (stride + getGpu()._threadsPerBlock - 1) / getGpu()._threadsPerBlock);
    kCalculateScaledMarginalCrossEntropyError_kernel<<<grid, getGpu()._threadsPerBlock>>>(position, stride, pUnit, pData);
    LAUNCHERROR("kCalculateScaledMarginalCrossEntropyError_kernel");
    getGpu()._pbAccumulator->Download();
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, T* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;
        NNFloat a               = pUnit[uOffset + pos];
        T t                     = pData[dOffset + pos];
        if (((t == (T)1.0) && (a < cData._SMCE_oneTarget)) || 
            ((t == (T)0.0) && (a > cData._SMCE_zeroTarget)))
            error               = -t * cData._SMCE_oneScale * log(max(MIN_ERROR, a)) - ( (NNFloat)1.0 - t) * cData._SMCE_zeroScale * log(max(MIN_ERROR, (NNFloat)1.0 - a));     
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 128.0);
        if (((t == (NNFloat)1.0) && (a < cData._SMCE_oneTarget)) || ((t == (NNFloat)0.0) && (a > cData._SMCE_zeroTarget)))
            error               = -t * cData._SMCE_oneScale * log(max(MIN_ERROR, a)) - ((NNFloat)1.0 - t) * cData._SMCE_zeroScale * log(max(MIN_ERROR, (NNFloat)1.0 - a));  
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, unsigned char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 256.0);
        if (((t == (NNFloat)1.0) && (a < cData._SMCE_oneTarget)) || ((t == (NNFloat)0.0) && (a > cData._SMCE_zeroTarget)))
            error               = -t * cData._SMCE_oneScale * log(max(MIN_ERROR, a)) - ((NNFloat)1.0 - t) * cData._SMCE_zeroScale * log(max(MIN_ERROR, (NNFloat)1.0 - a));  
        //printf("%d %llu %f %f %f\n", position, pos, a, t, error);
    }

    REDUCEERROR(error)
}

template<typename T> NNFloat kCalculateIndexedScaledMarginalCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, T* pData)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    dim3 grid(batch, (stride + getGpu()._threadsPerBlock - 1) / getGpu()._threadsPerBlock);
    kCalculateIndexedScaledMarginalCrossEntropyError_kernel<<<grid, getGpu()._threadsPerBlock>>>(position, stride, pUnit, pIndex, pData);
    LAUNCHERROR("kCalculateIndexedScaledMarginalCrossEntropyError_kernel");
    getGpu()._pbAccumulator->Download();
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateMultinomialScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, T* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = (cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x) * stride;
        NNFloat a               = pUnit[uOffset + pos];
        T t                     = pData[dOffset + pos];
        if ((t != (T)0.0) && (a < cData._SMCE_oneTarget)) 
            error               = -t * cData._SMCE_oneScale * log(max(MIN_ERROR, a));
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateMultinomialScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = (cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x) * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 128.0);
        if ((t != (NNFloat)0.0) && (a < cData._SMCE_oneTarget)) 
            error               = -t * cData._SMCE_oneScale * log(max(MIN_ERROR, a));  
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateMultinomialScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, unsigned char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = (cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x) * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 256.0);
        if ((t != (NNFloat)0.0) && (a < cData._SMCE_oneTarget))
            error               = -t * cData._SMCE_oneScale * log(max(MIN_ERROR, a));  
    }

    REDUCEERROR(error)
}

template<typename T> NNFloat kCalculateMultinomialScaledMarginalCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, T* pData)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    dim3 grid(batch, (stride + getGpu()._threadsPerBlock - 1) / getGpu()._threadsPerBlock);
    kCalculateMultinomialScaledMarginalCrossEntropyError_kernel<<<grid, getGpu()._threadsPerBlock>>>(position, stride, pUnit, pData);
    LAUNCHERROR("kCalculateMultinomialScaledMarginalCrossEntropyError_kernel");
    getGpu()._pbAccumulator->Download();
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

template<typename T>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedMultinomialScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, T* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;
        NNFloat a               = pUnit[uOffset + pos];
        T t                     = pData[dOffset + pos];
        if ((t != (T)0.0) && (a < cData._SMCE_oneTarget)) 
            error               = -t * cData._SMCE_oneScale * log(max(MIN_ERROR, a));
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedMultinomialScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 128.0);
        if ((t != (NNFloat)0.0) && (a < cData._SMCE_oneTarget)) 
            error               = -t * cData._SMCE_oneScale * log(max(MIN_ERROR, a));  
    }

    REDUCEERROR(error)
}

template<>
__global__ void
LAUNCH_BOUNDS()
kCalculateIndexedMultinomialScaledMarginalCrossEntropyError_kernel(uint32_t position, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, unsigned char* pData)
{
    uint64_t pos                = (blockIdx.y * blockDim.x) + threadIdx.x;
    NNFloat error               = (NNFloat)0.0;
    if (pos < stride)
    {
        uint64_t uOffset        = blockIdx.x * stride;
        uint64_t dOffset        = pIndex[cData._bShuffleIndices ? cData._pShuffleIndex[position + blockIdx.x] : position + blockIdx.x] * stride;
        NNFloat a               = pUnit[uOffset + pos];
        NNFloat t               = (NNFloat)pData[dOffset + pos] * (NNFloat)(1.0 / 256.0);
        if ((t != (NNFloat)0.0) && (a < cData._SMCE_oneTarget))
            error               = -t * cData._SMCE_oneScale * log(max(MIN_ERROR, a));  
    }

    REDUCEERROR(error)
}

template<typename T> NNFloat kCalculateIndexedMultinomialScaledMarginalCrossEntropyError(uint32_t position, uint32_t batch, uint32_t stride, NNFloat* pUnit, uint32_t* pIndex, T* pData)
{
    cudaMemset(getGpu()._data._pAccumulator, 0, sizeof(uint64_t));
    dim3 grid(batch, (stride + getGpu()._threadsPerBlock - 1) / getGpu()._threadsPerBlock);
    kCalculateIndexedMultinomialScaledMarginalCrossEntropyError_kernel<<<grid, getGpu()._threadsPerBlock>>>(position, stride, pUnit, pIndex, pData);
    LAUNCHERROR("kCalculateIndexedMultinomialScaledMarginalCrossEntropyError_kernel");
    getGpu()._pbAccumulator->Download();
    return (NNFloat)((double)(getGpu()._pbAccumulator->_pSysData[0]) * ONEOVERERRORSCALE);
}

// Instantiates allowable templated functions so we can hide the implementations here
// instead of in the header file because we're mixing CUDA and C++ and that's
// a migraine headache in the making otherwise.
#define EXPLICITLY_INSTANTIATE_KERNELS(T)                                                                                                                                            \
template NNFloat kCalculateL1Error<T>(uint32_t, uint32_t, uint32_t, NNFloat*, T*);                                                                                                   \
template NNFloat kCalculateIndexedL1Error<T>(uint32_t, uint32_t, uint32_t, NNFloat*, uint32_t*, T*);                                                                                 \
template NNFloat kCalculateL2Error<T>(uint32_t, uint32_t, uint32_t, NNFloat*, T*);                                                                                                   \
template NNFloat kCalculateIndexedL2Error<T>(uint32_t, uint32_t, uint32_t, NNFloat*, uint32_t*, T*);                                                                                 \
template NNFloat kCalculateCrossEntropyError<T>(uint32_t, uint32_t, uint32_t, NNFloat*, T*);                                                                                         \
template NNFloat kCalculateIndexedCrossEntropyError<T>(uint32_t, uint32_t, uint32_t, NNFloat*, uint32_t*, T*);                                                                       \
template NNFloat kCalculateScaledMarginalCrossEntropyError<T>(uint32_t, uint32_t, uint32_t, NNFloat*, T*);                                                                           \
template NNFloat kCalculateIndexedScaledMarginalCrossEntropyError<T>(uint32_t, uint32_t, uint32_t, NNFloat*, uint32_t*, T*);                                                         \
template NNFloat kCalculateMultinomialCrossEntropyError<T>(uint32_t, uint32_t, uint32_t, NNFloat*, T*);                                                                              \
template NNFloat kCalculateIndexedMultinomialCrossEntropyError<T>(uint32_t, uint32_t, uint32_t, NNFloat*, uint32_t*, T*);                                                            \
template NNFloat kCalculateMultinomialScaledMarginalCrossEntropyError<T>(uint32_t, uint32_t, uint32_t, NNFloat*, T*);                                                                \
template NNFloat kCalculateIndexedMultinomialScaledMarginalCrossEntropyError<T>(uint32_t, uint32_t, uint32_t, NNFloat*, uint32_t*, T*);                                              \
template NNFloat kCalculateHingeError<T>(uint32_t, uint32_t, uint32_t, NNFloat*, T*);                                                                                                \
template NNFloat kCalculateIndexedHingeError<T>(uint32_t, uint32_t, uint32_t, NNFloat*, uint32_t*, T*);                                                                              \
template NNFloat kCalculateSparseAnalogL1Error<T>(uint32_t, uint32_t, uint32_t, NNFloat*, uint64_t*, uint64_t*, uint32_t*, NNFloat* pSparseWeight, T*, bool);                                                \
template NNFloat kCalculateIndexedSparseAnalogL1Error<T>(uint32_t, uint32_t, uint32_t, NNFloat*, uint32_t*, uint64_t*, uint64_t*, uint32_t*, NNFloat* pSparseWeight, T*, bool);                              \
template NNFloat kCalculateSparseAnalogL2Error<T>(uint32_t, uint32_t, uint32_t, NNFloat*, uint64_t*, uint64_t*, uint32_t*, NNFloat* pSparseWeight, T*, bool);                                                \
template NNFloat kCalculateIndexedSparseAnalogL2Error<T>(uint32_t, uint32_t, uint32_t, NNFloat*, uint32_t*, uint64_t*, uint64_t*, uint32_t*, NNFloat* pSparseWeight, T*, bool);                              \
template NNFloat kCalculateSparseAnalogMultinomialCrossEntropyError<T>(uint32_t, uint32_t, uint32_t, NNFloat*, uint64_t*, uint64_t*, uint32_t*, NNFloat* pSparseWeight, T*);                                 \
template NNFloat kCalculateIndexedSparseAnalogMultinomialCrossEntropyError<T>(uint32_t, uint32_t, uint32_t, NNFloat*, uint32_t*, uint64_t*, uint64_t*, uint32_t*, NNFloat* pSparseWeight, T*);               \
template NNFloat kCalculateSparseAnalogMultinomialScaledMarginalCrossEntropyError<T>(uint32_t, uint32_t, uint32_t, NNFloat*, uint64_t*, uint64_t*, uint32_t*, NNFloat* pSparseWeight, T*);                   \
template NNFloat kCalculateIndexedSparseAnalogMultinomialScaledMarginalCrossEntropyError<T>(uint32_t, uint32_t, uint32_t, NNFloat*, uint32_t*, uint64_t*, uint64_t*, uint32_t*, NNFloat* pSparseWeight, T*); \
template NNFloat kCalculateSparseDataScaledMarginalCrossEntropyError<T>(uint32_t, uint32_t, uint32_t, NNFloat*, uint64_t*, uint64_t*, uint32_t*, T*, bool);                                                  \
template NNFloat kCalculateIndexedSparseDataScaledMarginalCrossEntropyError<T>(uint32_t, uint32_t, uint32_t, NNFloat*, uint32_t*, uint64_t*, uint64_t*, uint32_t*, T*, bool);                                \
/**/

EXPLICITLY_INSTANTIATE_KERNELS(NNFloat)
EXPLICITLY_INSTANTIATE_KERNELS(double)
EXPLICITLY_INSTANTIATE_KERNELS(unsigned char)
EXPLICITLY_INSTANTIATE_KERNELS(char)
EXPLICITLY_INSTANTIATE_KERNELS(uint32_t)
EXPLICITLY_INSTANTIATE_KERNELS(uint64_t)
EXPLICITLY_INSTANTIATE_KERNELS(int32_t)
EXPLICITLY_INSTANTIATE_KERNELS(int64_t)
