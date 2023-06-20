/*
* Copyright (c) 2023, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#pragma pack_matrix(row_major)

#include <donut/shaders/bindless.h>
#include <donut/shaders/vulkan.hlsli>
#include <donut/shaders/packing.hlsli>
#include "../../external/RTXDI/rtxdi-sdk/include/rtxdi/RtxdiMath.hlsli"
#include "ShaderParameters.h"
#include "../PathTracer/ShaderDebug.hlsli"

VK_PUSH_CONSTANT ConstantBuffer<PrepareLightsConstants> g_Const : register(b0);
RWStructuredBuffer<PolymorphicLightInfo> u_LightDataBuffer      : register(u0);
RWBuffer<uint> u_LightIndexMappingBuffer                        : register(u1);
RWTexture2D<float> u_LocalLightPdfTexture                       : register(u2);
StructuredBuffer<PrepareLightsTask> t_TaskBuffer                : register(t0);
StructuredBuffer<PolymorphicLightInfo> t_PrimitiveLights        : register(t1);
StructuredBuffer<InstanceData> t_InstanceData                   : register(t2);
StructuredBuffer<GeometryData> t_GeometryData                   : register(t3);
StructuredBuffer<GeometryDebugData> t_GeometryDebugData         : register(t4);
StructuredBuffer<MaterialConstants> t_MaterialConstants         : register(t5);
Texture2D<float4> t_EnvironmentMap                              : register(t6);
SamplerState s_MaterialSampler                                  : register(s0);
SamplerState s_EnvironmentMapSampler                            : register(s1);

// this is for debugging viz
RWTexture2D<float4>                     u_DebugVizOutput        : register(u50);

VK_BINDING(0, 1) ByteAddressBuffer t_BindlessBuffers[]          : register(t0, space1);
VK_BINDING(1, 1) Texture2D t_BindlessTextures[]                 : register(t0, space2);

#define ENVIRONMENT_SAMPLER s_EnvironmentMapSampler 
#define IES_SAMPLER s_MaterialSampler
#include "PolymorphicLight.hlsli"

bool FindTask(uint dispatchThreadId, out PrepareLightsTask task)
{
    // Use binary search to find the task that contains the current thread's output index:
    //   task.lightBufferOffset <= dispatchThreadId < (task.lightBufferOffset + task.triangleCount)

    int left = 0;
    int right = int(g_Const.numTasks) - 1;

    while (right >= left)
    {
        int middle = (left + right) / 2;
        task = t_TaskBuffer[middle];

        int tri = int(dispatchThreadId) - int(task.lightBufferOffset); // signed

        if (tri < 0)
        {
            // Go left
            right = middle - 1;
        }
        else if (tri < task.triangleCount)
        {
            // Found it!
            return true;
        }
        else
        {
            // Go right
            left = middle + 1;
        }
    }

    return false;
}

[numthreads(256, 1, 1)]
void main(uint dispatchThreadId : SV_DispatchThreadID, uint groupThreadId : SV_GroupThreadID)
{
    PrepareLightsTask task = (PrepareLightsTask)0;

    if (!FindTask(dispatchThreadId, task))
        return;

    uint triangleIdx = dispatchThreadId - task.lightBufferOffset;
    bool isPrimitiveLight = (task.instanceAndGeometryIndex & TASK_PRIMITIVE_LIGHT_BIT) != 0;
    
    PolymorphicLightInfo lightInfo = (PolymorphicLightInfo)0;

    if (!isPrimitiveLight)
    {
        InstanceData instance = t_InstanceData[(task.instanceAndGeometryIndex >> 12) & 0x7FFFF];
        GeometryData geometry = t_GeometryData[instance.firstGeometryIndex + (task.instanceAndGeometryIndex & 0xfff)];
        MaterialConstants material = t_MaterialConstants[geometry.materialIndex];

        ByteAddressBuffer indexBuffer = t_BindlessBuffers[NonUniformResourceIndex(geometry.indexBufferIndex)];
        ByteAddressBuffer vertexBuffer = t_BindlessBuffers[NonUniformResourceIndex(geometry.vertexBufferIndex)];
        
        uint3 indices = indexBuffer.Load3(geometry.indexOffset + triangleIdx * c_SizeOfTriangleIndices);

        float3 positions[3];

        positions[0] = asfloat(vertexBuffer.Load3(geometry.positionOffset + indices[0] * c_SizeOfPosition));
        positions[1] = asfloat(vertexBuffer.Load3(geometry.positionOffset + indices[1] * c_SizeOfPosition));
        positions[2] = asfloat(vertexBuffer.Load3(geometry.positionOffset + indices[2] * c_SizeOfPosition));
        
        positions[0] = mul(instance.transform, float4(positions[0], 1)).xyz;
        positions[1] = mul(instance.transform, float4(positions[1], 1)).xyz;
        positions[2] = mul(instance.transform, float4(positions[2], 1)).xyz;

        float3 radiance = material.emissiveColor;

        if ((material.emissiveTextureIndex != 0xFFFFFFFF) && (geometry.texCoord1Offset != ~0u) && ((material.flags & MaterialFlags_UseEmissiveTexture) != 0))
        {
            Texture2D emissiveTexture = t_BindlessTextures[NonUniformResourceIndex(material.emissiveTextureIndex & 0xFFFF)];

            // Load the vertex UVs
            float2 uvs[3];
            uvs[0] = asfloat(vertexBuffer.Load2(geometry.texCoord1Offset + indices[0] * c_SizeOfTexcoord));
            uvs[1] = asfloat(vertexBuffer.Load2(geometry.texCoord1Offset + indices[1] * c_SizeOfTexcoord));
            uvs[2] = asfloat(vertexBuffer.Load2(geometry.texCoord1Offset + indices[2] * c_SizeOfTexcoord));

            // Calculate the triangle edges and edge lengths in UV space
            float2 edges[3];
            edges[0] = uvs[1] - uvs[0];
            edges[1] = uvs[2] - uvs[1];
            edges[2] = uvs[0] - uvs[2];

            float3 edgeLengths;
            edgeLengths[0] = length(edges[0]);
            edgeLengths[1] = length(edges[1]);
            edgeLengths[2] = length(edges[2]);

            // Find the shortest edge and the other two (longer) edges
            float2 shortEdge;
            float2 longEdge1;
            float2 longEdge2;

            if (edgeLengths[0] < edgeLengths[1] && edgeLengths[0] < edgeLengths[2])
            {
                shortEdge = edges[0];
                longEdge1 = edges[1];
                longEdge2 = edges[2];
            }
            else if (edgeLengths[1] < edgeLengths[2])
            {
                shortEdge = edges[1];
                longEdge1 = edges[2];
                longEdge2 = edges[0];
            }
            else
            {
                shortEdge = edges[2];
                longEdge1 = edges[0];
                longEdge2 = edges[1];
            }

            // Use anisotropic sampling with the sample ellipse axes parallel to the short edge
            // and the median from the opposite vertex to the short edge.
            // This ellipse is roughly inscribed into the triangle and approximates long or skinny
            // triangles with highly anisotropic sampling, and is mostly round for usual triangles.
            float2 shortGradient = shortEdge * (2.0 / 3.0);
            float2 longGradient = (longEdge1 + longEdge2) / 3.0;

            // Sample
            float2 centerUV = (uvs[0] + uvs[1] + uvs[2]) / 3.0;
            float3 emissiveMask = emissiveTexture.SampleGrad(s_MaterialSampler, centerUV, shortGradient, longGradient).rgb;

            radiance *= emissiveMask;
        }

        radiance.rgb = max(0, radiance.rgb);

        // Check if the transform flips the coordinate system handedness (its determinant is negative).
        float3x3 transform;
        transform._m00_m01_m02 = (instance.transform._m00_m01_m02);
        transform._m10_m11_m12 = (instance.transform._m10_m11_m12);
        transform._m20_m21_m22 = (instance.transform._m20_m21_m22);

        bool isFlipped = determinant(transform) < 0.f;

        TriangleLight triLight;
        triLight.base = positions[0];
        if (!isFlipped)
        {
            triLight.edge1 = positions[1] - positions[0];
            triLight.edge2 = positions[2] - positions[0];
        }
        else
        {
            triLight.edge1 = positions[2] - positions[0];
            triLight.edge2 = positions[1] - positions[0];
        }
        triLight.radiance = radiance;
        
        lightInfo = triLight.Store();
    }
    else
    {
        uint primitiveLightIndex = task.instanceAndGeometryIndex & ~TASK_PRIMITIVE_LIGHT_BIT;
        lightInfo = t_PrimitiveLights[primitiveLightIndex];
    }

    uint lightBufferPtr = task.lightBufferOffset + triangleIdx;
    u_LightDataBuffer[g_Const.currentFrameLightOffset + lightBufferPtr] = lightInfo;

    // If this light has existed on the previous frame, write the index mapping information
    // so that temporal resampling can be applied to the light correctly when it changes
    // the index inside the light buffer.
    if (task.previousLightBufferOffset >= 0)
    {
        uint prevBufferPtr = task.previousLightBufferOffset + triangleIdx;

        // Mapping buffer for the previous frame points at the current frame.
        // Add one to indicate that this is a valid mapping, zero is invalid.
        u_LightIndexMappingBuffer[g_Const.previousFrameLightOffset + prevBufferPtr] = 
            g_Const.currentFrameLightOffset + lightBufferPtr + 1;

        // Mapping buffer for the current frame points at the previous frame.
        // Add one to indicate that this is a valid mapping, zero is invalid.
        u_LightIndexMappingBuffer[g_Const.currentFrameLightOffset + lightBufferPtr] = 
            g_Const.previousFrameLightOffset + prevBufferPtr + 1;
    }

    // Calculate the total flux
    // We do not have to check light types as getPower handles directional and environment lights (returns zero)
    float emissiveFlux = PolymorphicLight::getPower(lightInfo);

    // Write the flux into the PDF texture
    uint2 pdfTexturePosition = RTXDI_LinearIndexToZCurve(lightBufferPtr);
    u_LocalLightPdfTexture[pdfTexturePosition] = emissiveFlux;
}
