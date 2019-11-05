#ifndef LWRP_AnisotropicLighting_INCLUDED
#define LWRP_AnisotropicLighting_INCLUDED

#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/EntityLighting.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/ImageBasedLighting.hlsl"
#include "Packages/com.unity.render-pipelines.lightweight/ShaderLibrary/Core.hlsl"
#include "Packages/com.unity.render-pipelines.lightweight/ShaderLibrary/Shadows.hlsl"

// If lightmap is not defined than we evaluate GI (ambient + probes) from SH
// We might do it fully or partially in vertex to save shader ALU
#if !defined(LIGHTMAP_ON)
// TODO: Controls things like these by exposing SHADER_QUALITY levels (low, medium, high)
#if defined(SHADER_API_GLES) || !defined(_NORMALMAP)
	// Evaluates SH fully in vertex
#define EVALUATE_SH_VERTEX
#elif !SHADER_HINT_NICE_QUALITY
	// Evaluates L2 SH in vertex and L0L1 in pixel
#define EVALUATE_SH_MIXED
#endif
	// Otherwise evaluate SH fully per-pixel
#endif


#ifdef LIGHTMAP_ON
#define DECLARE_LIGHTMAP_OR_SH(lmName, shName, index) float2 lmName : TEXCOORD##index
#define OUTPUT_LIGHTMAP_UV(lightmapUV, lightmapScaleOffset, OUT) OUT.xy = lightmapUV.xy * lightmapScaleOffset.xy + lightmapScaleOffset.zw;
#define OUTPUT_SH(normalWS, OUT)
#else
#define DECLARE_LIGHTMAP_OR_SH(lmName, shName, index) half3 shName : TEXCOORD##index
#define OUTPUT_LIGHTMAP_UV(lightmapUV, lightmapScaleOffset, OUT)
#define OUTPUT_SH(normalWS, OUT) OUT.xyz = SampleSHVertex(normalWS)
#endif

#ifdef UNITY_COLORSPACE_GAMMA
#define unity_ColorSpaceDielectricSpec half4(0.220916301, 0.220916301, 0.220916301, 1.0 - 0.220916301)
#define unity_ColorSpaceLuminance half4(0.22, 0.707, 0.071, 0.0) // Legacy: alpha is set to 0.0 to specify gamma mode
#else // Linear values
#define unity_ColorSpaceDielectricSpec half4(0.04, 0.04, 0.04, 1.0 - 0.04) // standard dielectric reflectivity coef at incident angle (= 4%)
#define unity_ColorSpaceLuminance half4(0.0396819152, 0.458021790, 0.00609653955, 1.0) // Legacy: alpha is set to 1.0 to specify linear mode
#endif

#define UNITY_INV_PI        0.31830988618f

struct DiffuseSpecluarOMR
{
	half3 diffuseColor;
	half3 specColor;
	half oneMinusReflectivity;
};

inline half OneMinusReflectivityFromMetallic(half metallic)
{
	// We'll need oneMinusReflectivity, so
	//   1-reflectivity = 1-lerp(dielectricSpec, 1, metallic) = lerp(1-dielectricSpec, 0, metallic)
	// store (1-dielectricSpec) in unity_ColorSpaceDielectricSpec.a, then
	//   1-reflectivity = lerp(alpha, 0, metallic) = alpha + metallic*(0 - alpha) =
	//                  = alpha - metallic * alpha
	half oneMinusDielectricSpec = unity_ColorSpaceDielectricSpec.a;
	return oneMinusDielectricSpec - metallic * oneMinusDielectricSpec;
}

half3 DiffuseAndSpecularFromMetallic(half3 albedo, half metallic, out half3 specColor, out half oneMinusReflectivity)
{
	specColor = lerp(unity_ColorSpaceDielectricSpec.rgb, albedo, metallic);
	oneMinusReflectivity = OneMinusReflectivityFromMetallic(metallic);
	return albedo * oneMinusReflectivity;
}

inline half Pow5(half x)
{
	return x * x * x * x * x;
}

inline half Pow4(half x)
{
	return x * x * x * x;
}

inline half3 FresnelLerp(half3 F0, half3 F90, half cosA)
{
	half t = Pow5(1 - cosA);   // ala Schlick interpoliation
	return lerp(F0, F90, t);
}

inline half3 FresnelLerpFast(half3 F0, half3 F90, half cosA)
{
	half t = Pow4(1 - cosA);
	return lerp(F0, F90, t);
}

float SmoothnessToPerceptualRoughness(float smoothness)
{
	return (1 - smoothness);
}


void DisneyPrincipled_Isotropic_RoughnessTB(float r2, float Kaniso, out float rT, out float rB)
{
	//rT roughness along bitangent
	//rB roughness along tangent 

	float Kaspect = sqrt(1.0 - 0.9 * Kaniso);

	//Disney pricipled shading model Anisotropic Roughness Function.  Real-Time Rendering Page 345.  Graph 9.54.  
	//rT = r2 / Kaspect;						
	//rB = r2 * Kaspect;						

	//Imageworks use this parameterization that allow for an abritrary degree of anisotropy.  Real-Time Rendering Page 345. Graph 9.54
	rT = r2 * (1 + Kaniso);
	rB = r2 * (1 - Kaniso);

	rT = max(rT, 0.0001f);
	rB = max(rB, 0.0001f);
}


//Anisotropic GGX NDF. Real-Time Rendering Page 345 Graph 
float GGXAnisotropicNDF(float TH, float BH, float NH, float rT, float rB)
{
	float TH2 = TH * TH;
	float BH2 = BH * BH;
	float NH2 = NH * NH;
	float rT2 = rT * rT;
	float rB2 = rB * rB;

	float tbnM = (TH2 / rB) + (BH2 / rB2) + NH2;

	// XXX
	// Zhu,Wei
	//This is the original version of GGXAnisotropicNDF, the denominator scale by PI will cause the specular light too dark.
	//I don't know what's going on
	//return 1.0 * UNITY_INV_PI / (rT * rB * tbnM * tbnM);

	return 1.0 / (rT * rB * tbnM * tbnM);
}


float GGXAnisotropicG2(float TV, float BV, float NV, float TL, float BL, float NL, float rT, float rB)
{	
	//SmithJoint
	float T2 = rT * rT;
	float B2 = rB * rB;

	float TV2 = TV * TV;
	float BV2 = BV * BV;
	float NV2 = NV * NV;
	float TL2 = TL * TL;
	float BL2 = BL * BL;
	float NL2 = NL * NL;

	float lambdaV = NL * sqrt((T2 * TV2) + (B2 * BV2) + NV2);
	float lambdaL = NV * sqrt((T2 * TL2) + (B2 * BL2) + NL2);

	return 0.5 / (lambdaV + lambdaL);
}

inline half3 FresnelTerm(half3 F0, half cosA)
{
	half t = Pow5(1 - cosA);   // ala Schlick interpoliation
	return F0 + (1 - F0) * t;
}

///////////////////////////////////////////////////////////////////////////////
//                          Light Helpers                                    //
///////////////////////////////////////////////////////////////////////////////


struct Light
{
	half3   dir;
	half3   color;
	half    distanceAttenuation;
	half    shadowAttenuation;
};

struct Indirect
{
	half3 diffuse;
	half3 specular;
};

//=====================================================
int GetPerObjectLightIndex(int index)
{
	// The following code is more optimal than indexing unity_4LightIndices0.
	// Conditional moves are branch free even on mali-400
	half2 lightIndex2 = (index < 2.0h) ? unity_LightIndices[0].xy : unity_LightIndices[0].zw;
	half i_rem = (index < 2.0h) ? index : index - 2.0h;
	return (i_rem < 1.0h) ? lightIndex2.x : lightIndex2.y;
}


// Matches Unity Vanila attenuation
// Attenuation smoothly decreases to light range.
float DistanceAttenuation(float distanceSqr, half2 distanceAttenuation)
{
	// We use a shared distance attenuation for additional directional and puctual lights
	// for directional lights attenuation will be 1
	float lightAtten = rcp(distanceSqr);

#if SHADER_HINT_NICE_QUALITY
	// Use the smoothing factor also used in the Unity lightmapper.
	half factor = distanceSqr * distanceAttenuation.x;
	half smoothFactor = saturate(1.0h - factor * factor);
	smoothFactor = smoothFactor * smoothFactor;
#else
	// We need to smoothly fade attenuation to light range. We start fading linearly at 80% of light range
	// Therefore:
	// fadeDistance = (0.8 * 0.8 * lightRangeSq)
	// smoothFactor = (lightRangeSqr - distanceSqr) / (lightRangeSqr - fadeDistance)
	// We can rewrite that to fit a MAD by doing
	// distanceSqr * (1.0 / (fadeDistanceSqr - lightRangeSqr)) + (-lightRangeSqr / (fadeDistanceSqr - lightRangeSqr)
	// distanceSqr *        distanceAttenuation.y            +             distanceAttenuation.z
	half smoothFactor = saturate(distanceSqr * distanceAttenuation.x + distanceAttenuation.y);
#endif

	return lightAtten * smoothFactor;
}

half AngleAttenuation(half3 spotDirection, half3 lightDirection, half2 spotAttenuation)
{
	// Spot Attenuation with a linear falloff can be defined as
	// (SdotL - cosOuterAngle) / (cosInnerAngle - cosOuterAngle)
	// This can be rewritten as
	// invAngleRange = 1.0 / (cosInnerAngle - cosOuterAngle)
	// SdotL * invAngleRange + (-cosOuterAngle * invAngleRange)
	// SdotL * spotAttenuation.x + spotAttenuation.y

	// If we precompute the terms in a MAD instruction
	half SdotL = dot(spotDirection, lightDirection);
	half atten = saturate(SdotL * spotAttenuation.x + spotAttenuation.y);
	return atten * atten;
}

Light GetAdditionalLight(int i, float3 positionWS)
{
	int perObjectLightIndex = GetPerObjectLightIndex(i);

	// The following code will turn into a branching madhouse on platforms that don't support
	// dynamic indexing. Ideally we need to configure light data at a cluster of
	// objects granularity level. We will only be able to do that when scriptable culling kicks in.
	// TODO: Use StructuredBuffer on PC/Console and profile access speed on mobile that support it.
	// Abstraction over Light input constants
	float3 lightPositionWS = _AdditionalLightsPosition[perObjectLightIndex].xyz;
	half4 distanceAndSpotAttenuation = _AdditionalLightsAttenuation[perObjectLightIndex];
	half4 spotDirection = _AdditionalLightsSpotDir[perObjectLightIndex];

	float3 lightVector = lightPositionWS - positionWS;
	float distanceSqr = max(dot(lightVector, lightVector), HALF_MIN);

	half3 lightDirection = half3(lightVector * rsqrt(distanceSqr));
	half attenuation = DistanceAttenuation(distanceSqr, distanceAndSpotAttenuation.xy) * AngleAttenuation(spotDirection.xyz, lightDirection, distanceAndSpotAttenuation.zw);

	Light light;
	light.dir = lightDirection;
	light.distanceAttenuation = attenuation;
	light.shadowAttenuation = AdditionalLightRealtimeShadow(perObjectLightIndex, positionWS);
	light.color = _AdditionalLightsColor[perObjectLightIndex].rgb;

	// In case we're using light probes, we can sample the attenuation from the `unity_ProbesOcclusion`
#if defined(LIGHTMAP_ON)
	// First find the probe channel from the light.
	// Then sample `unity_ProbesOcclusion` for the baked occlusion.
	// If the light is not baked, the channel is -1, and we need to apply no occlusion.
	half4 lightOcclusionProbeInfo = _AdditionalLightsOcclusionProbes[perObjectLightIndex];

	// probeChannel is the index in 'unity_ProbesOcclusion' that holds the proper occlusion value.
	int probeChannel = lightOcclusionProbeInfo.x;

	// lightProbeContribution is set to 0 if we are indeed using a probe, otherwise set to 1.
	half lightProbeContribution = lightOcclusionProbeInfo.y;

	half probeOcclusionValue = unity_ProbesOcclusion[probeChannel];
	light.distanceAttenuation *= max(probeOcclusionValue, lightProbeContribution);
#endif

	return light;
}

int GetAdditionalLightsCount()
{
	// TODO: we need to expose in SRP api an ability for the pipeline cap the amount of lights
	// in the culling. This way we could do the loop branch with an uniform
	// This would be helpful to support baking exceeding lights in SH as well
	return min(_AdditionalLightsCount.x, unity_LightData.y);
}


// Samples SH L0, L1 and L2 terms
half3 SampleSH(half3 normalWS)
{
	// LPPV is not supported in Ligthweight Pipeline
	real4 SHCoefficients[7];
	SHCoefficients[0] = unity_SHAr;
	SHCoefficients[1] = unity_SHAg;
	SHCoefficients[2] = unity_SHAb;
	SHCoefficients[3] = unity_SHBr;
	SHCoefficients[4] = unity_SHBg;
	SHCoefficients[5] = unity_SHBb;
	SHCoefficients[6] = unity_SHC;

	return max(half3(0, 0, 0), SampleSH9(SHCoefficients, normalWS));
}

// SH Vertex Evaluation. Depending on target SH sampling might be
// done completely per vertex or mixed with L2 term per vertex and L0, L1
// per pixel. See SampleSHPixel
half3 SampleSHVertex(half3 normalWS)
{
#if defined(EVALUATE_SH_VERTEX)
	return max(half3(0, 0, 0), SampleSH(normalWS));
#elif defined(EVALUATE_SH_MIXED)
	// no max since this is only L2 contribution
	return SHEvalLinearL2(normalWS, unity_SHBr, unity_SHBg, unity_SHBb, unity_SHC);
#endif

	// Fully per-pixel. Nothing to compute.
	return half3(0.0, 0.0, 0.0);
}

// SH Pixel Evaluation. Depending on target SH sampling might be done
// mixed or fully in pixel. See SampleSHVertex
half3 SampleSHPixel(half3 L2Term, half3 normalWS)
{
#if defined(EVALUATE_SH_VERTEX)
	return L2Term;
#elif defined(EVALUATE_SH_MIXED)
	half3 L0L1Term = SHEvalLinearL0L1(normalWS, unity_SHAr, unity_SHAg, unity_SHAb);
	return max(half3(0, 0, 0), L2Term + L0L1Term);
#endif

	// Default: Evaluate SH fully per-pixel
	return SampleSH(normalWS);
}

// Sample baked lightmap. Non-Direction and Directional if available.
// Realtime GI is not supported.
half3 SampleLightmap(float2 lightmapUV, half3 normalWS)
{
#ifdef UNITY_LIGHTMAP_FULL_HDR
	bool encodedLightmap = false;
	//return half3(1,0,0);
#else
	bool encodedLightmap = true;
	//return half3(0,1,0);
#endif

	half4 decodeInstructions = half4(LIGHTMAP_HDR_MULTIPLIER, LIGHTMAP_HDR_EXPONENT, 0.0h, 0.0h);

	// The shader library sample lightmap functions transform the lightmap uv coords to apply bias and scale.
	// However, lightweight pipeline already transformed those coords in vertex. We pass half4(1, 1, 0, 0) and
	// the compiler will optimize the transform away.
	half4 transformCoords = half4(1, 1, 0, 0);

#ifdef DIRLIGHTMAP_COMBINED
	return SampleDirectionalLightmap(TEXTURE2D_ARGS(unity_Lightmap, samplerunity_Lightmap),
		TEXTURE2D_ARGS(unity_LightmapInd, samplerunity_Lightmap),
		lightmapUV, transformCoords, normalWS, encodedLightmap, decodeInstructions);
#elif defined(LIGHTMAP_ON)
	return SampleSingleLightmap(TEXTURE2D_ARGS(unity_Lightmap, samplerunity_Lightmap), lightmapUV, transformCoords, encodedLightmap, decodeInstructions);
#else
	return half3(0.0, 0.0, 0.0);
#endif
}

half3 VertexLighting(float3 positionWS, half3 normalWS)
{
	half3 vertexLightColor = half3(0.0, 0.0, 0.0);

#ifdef _ADDITIONAL_LIGHTS_VERTEX
	int pixelLightCount = GetAdditionalLightsCount();
	for (int i = 0; i < pixelLightCount; ++i)
	{
		Light light = GetAdditionalLight(i, positionWS);
		half3 lightColor = light.color * light.distanceAttenuation;
		vertexLightColor += LightingLambert(lightColor, light.direction, normalWS);
	}
#endif

	return vertexLightColor;
}

// We either sample GI from baked lightmap or from probes.
// If lightmap: sampleData.xy = lightmapUV
// If probe: sampleData.xyz = L2 SH terms
#ifdef LIGHTMAP_ON
#define SAMPLE_GI(lmName, shName, normalWSName) SampleLightmap(lmName, normalWSName)
#else
#define SAMPLE_GI(lmName, shName, normalWSName) SampleSHPixel(shName, normalWSName)
#endif



Light GetMainLight()
{
	Light light;
	light.dir = _MainLightPosition.xyz;
	light.distanceAttenuation = unity_LightData.z;
#if defined(LIGHTMAP_ON)
	light.distanceAttenuation *= unity_ProbesOcclusion.x;
#endif
	light.shadowAttenuation = 1.0;
	light.color = _MainLightColor.rgb;
	return light;
}

Light GetMainLight(float4 shadowCoord)
{
	Light light = GetMainLight();
	light.shadowAttenuation = MainLightRealtimeShadow(shadowCoord);
	return light;
}

half3 GlossyEnvironmentReflection(half3 reflectVector, half perceptualRoughness, half occlusion)
{
#if !defined(_ENVIRONMENTREFLECTIONS_OFF)
	half mip = PerceptualRoughnessToMipmapLevel(perceptualRoughness);
	half4 encodedIrradiance = SAMPLE_TEXTURECUBE_LOD(unity_SpecCube0, samplerunity_SpecCube0, reflectVector, mip);

#if !defined(UNITY_USE_NATIVE_HDR)
	half3 irradiance = DecodeHDREnvironment(encodedIrradiance, unity_SpecCube0_HDR);
#else
	half3 irradiance = encodedIrradiance.rbg;
#endif

	return irradiance * occlusion;
#endif // GLOSSY_REFLECTIONS

	return _GlossyEnvironmentColor.rgb * occlusion;
}


half3 GetEnviromentReflection(half3 viewDirWS,half occlusion,half perceptualRoughness,half anisotropy,half3 btangentWS,half3 normalWS)
{
	float3 iblNormalWS = GetAnisotropicModifiedNormal(btangentWS, normalWS, viewDirWS, anisotropy);
	float3 iblR = reflect(-viewDirWS, iblNormalWS);
	return GlossyEnvironmentReflection(iblR,perceptualRoughness, occlusion);
}

half3 Normal_TS2WS(half3 normalTS,half3 tangentWS,half3 bitangentWS,half3 normalWS)
{
	return TransformTangentToWorld(normalTS, half3x3(tangentWS, bitangentWS, normalWS));
}

DiffuseSpecluarOMR GetDiffuseSpecularOneMinusReflectivity(half3 albedo,half metallic)
{
	DiffuseSpecluarOMR dso;
	dso.diffuseColor = DiffuseAndSpecularFromMetallic(albedo, metallic, dso.specColor, dso.oneMinusReflectivity);
	return dso;
}


float4 LWRP_AnisotropicBRDF(float3 diffColor, float3 specColor, float oneMinusReflectivity, float smoothness, float anisotropy, float metallic,
							 float3 viewDir, float3 normal, half3 tangentWS, half3 bitangentWS, Light light, Indirect gi)
{
	//Normal Properties
	float NL = saturate(dot(normal, light.dir));
	float NV = abs(dot(normal, viewDir));
	float3 H = SafeNormalize(light.dir + viewDir);
	float NH = saturate(dot(normal, H));
	//Tangent Propertis
	float TH = dot(tangentWS, H);
	float TL = dot(tangentWS, light.dir);
	float BH = dot(bitangentWS, H);
	float BL = dot(bitangentWS, light.dir);
	float TV = dot(viewDir, tangentWS);
	float BV = dot(viewDir, bitangentWS);

	float perceptualRoughness = SmoothnessToPerceptualRoughness(smoothness);
	float roughness = PerceptualRoughnessToRoughness(perceptualRoughness);

	float rT, rB;
	DisneyPrincipled_Isotropic_RoughnessTB(roughness, anisotropy, rT, rB);
	float V = GGXAnisotropicG2(TV, BV, NV, TL, BL, NL, rT, rB);
	float D = GGXAnisotropicNDF(TH, BH, NH, rT, rB);
	//Specular term; Unity Standard Shader Apply Fresnel Term later. So do I.
	float3 specularTerm = V * D;
#	ifdef UNITY_COLORSPACE_GAMMA
	specularTerm = sqrt(max(1e-4h, specularTerm));
#	endif
	// specularTerm * nl can be NaN on Metal in some cases, use max() to make sure it's a sane value
	specularTerm = max(0, specularTerm * NL);
#if defined(_SPECULARHIGHLIGHTS_OFF)
	specularTerm = 0.0;
#endif
	//Zhu,wei: For performance reason, We dont use DisneyDiffuse
	//float diffuseTerm = DisneyDiffuse(NV, NL, LH, perceptualRoughness) * NL;
	half surfaceReduction;
#ifdef UNITY_COLORSPACE_GAMMA
	surfaceReduction = 1.0 - 0.28 * roughness * perceptualRoughness;		
#else
	surfaceReduction = 1.0 / (roughness * roughness + 1.0);		
#endif
	half grazingTerm = saturate(smoothness + (1 - oneMinusReflectivity));													
	//half3 color = (diffColor * (gi.diffuse + light.color * diffuseTerm))
	//	+ specularTerm * light.color * FresnelTerm(specColor, LH) * _SpecColor
	//	+ surfaceReduction * gi.specular * FresnelLerp(specColor, grazingTerm, NV) * _SpecColor;
	/*  XXX
		Zhu,Wei:
		Apply Light radiance here.  Unity LWRP apply this and fake Frenel(NL) out side of the main BRDF function
	*/
	light.color *= light.distanceAttenuation * light.shadowAttenuation;

	half3 color = (diffColor + specularTerm * specColor) * light.color * NL				//Direct BRDF   here we just use NL simply replace the Fresnel term.
		+ gi.diffuse * diffColor	//GI 
		+ surfaceReduction * gi.specular * FresnelLerpFast(specColor, grazingTerm, NV);

	return half4(color, 1);
}

/*
struct SurfaceData
{
	half3 albedo;
	half3 specular;
	half  metallic;
	half  smoothness;
	half3 normalTS;
	half3 emission;
	half  occlusion;
	half  alpha;
};

struct InputData
{
	float3  positionWS;
	half3   normalWS;
	half3   viewDirectionWS;
	float4  shadowCoord;
	half    fogCoord;
	half3   vertexLighting;
	half3   bakedGI;
#if defined(LIGHTMAP_ON) && defined(SHADOWS_SHADOWMASK)
	//half    shadowMask;	// Modify By vanCopper
	half4	bakedAtten;
#endif
};


*/

half4 LWRP_AnisotropicBRDF(InputData inputData, half3 albedo, half metallic, half3 specular,
	half smoothness, half occlusion, half3 emission, half alpha,half anisotropy,half3 tangentWS,half3 bTangentWS)
{
	DiffuseSpecluarOMR dso = GetDiffuseSpecularOneMinusReflectivity(albedo,metallic);

	/*
		XXX 
		Zhu,Wei:
			TO custormize the specular color. So I just Tint the material's specular color.
		This will break the PBR BRDF property. For realistic rendering, this should not be apply
	*/
	dso.specColor *= _SpecColor.rgb;

	Light mainLight = GetMainLight(inputData.shadowCoord);

	half preceptualRoughness = PerceptualSmoothnessToPerceptualRoughness(smoothness);

	Indirect indirect;
	indirect.diffuse = inputData.bakedGI * occlusion;
	indirect.specular = GetEnviromentReflection(inputData.viewDirectionWS, occlusion, preceptualRoughness, anisotropy,bTangentWS,inputData.normalWS);


	return LWRP_AnisotropicBRDF(dso.diffuseColor,dso.specColor, dso.oneMinusReflectivity, smoothness, anisotropy,metallic, 
								inputData.viewDirectionWS,inputData.normalWS, tangentWS, bTangentWS, mainLight, indirect);
}

#endif
