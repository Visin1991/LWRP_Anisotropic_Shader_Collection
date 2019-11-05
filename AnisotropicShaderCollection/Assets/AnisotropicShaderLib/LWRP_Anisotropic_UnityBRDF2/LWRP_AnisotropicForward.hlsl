#ifndef LWRP_AnisotropicForward_INCLUDED
#define LWRP_AnisotropicForward_INCLUDED

#include "LWRP_AnisotropicLighting.hlsl"


struct Attributes
{
	float4 positionOS   : POSITION;
	float3 normalOS     : NORMAL;
	float4 tangentOS    : TANGENT;
	float2 texcoord     : TEXCOORD0;
	float2 lightmapUV   : TEXCOORD1;
	UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct Varyings
{
	float2 uv                       : TEXCOORD0;
	DECLARE_LIGHTMAP_OR_SH(lightmapUV, vertexSH, 1);

#ifdef _ADDITIONAL_LIGHTS
	float3 positionWS               : TEXCOORD2;
#endif


	half4 normalWS                  : TEXCOORD3;    // xyz: normal, w: viewDir.x
	half4 tangentWS                 : TEXCOORD4;    // xyz: tangent, w: viewDir.y
	half4 bitangentWS                : TEXCOORD5;    // xyz: bitangent, w: viewDir.z


	half4 fogFactorAndVertexLight   : TEXCOORD6; // x: fogFactor, yzw: vertex light

#ifdef _MAIN_LIGHT_SHADOWS
	float4 shadowCoord              : TEXCOORD7;
#endif

	float4 positionCS               : SV_POSITION;
	UNITY_VERTEX_INPUT_INSTANCE_ID
		UNITY_VERTEX_OUTPUT_STEREO
};


//TODO: 先使用脚本上传 shadowMask的图, 后面调研是否可写入到lightmap贴图的a通道中
//sampler2D lmShadowMask; // Modify By vanCopper
void InitializeInputData(Varyings input, half3 normalTS, out InputData inputData)
{
	inputData = (InputData)0;

#ifdef _ADDITIONAL_LIGHTS
	inputData.positionWS = input.positionWS;
#endif

	/*
		No Matter what, Anisotropic Shader always need Tangent and BitTangent Information
		So just do the normal mapping as default
																		------Zhu,Wei   10/27/2019
	*/
	half3 viewDirWS = half3(input.normalWS.w, input.tangentWS.w, input.bitangentWS.w);
	inputData.normalWS = TransformTangentToWorld(normalTS,
		half3x3(input.tangentWS.xyz, input.bitangentWS.xyz, input.normalWS.xyz));


	inputData.normalWS = NormalizeNormalPerPixel(inputData.normalWS);
	viewDirWS = SafeNormalize(viewDirWS);

	inputData.viewDirectionWS = viewDirWS;

#if defined(_MAIN_LIGHT_SHADOWS) && !defined(_RECEIVE_SHADOWS_OFF)
	inputData.shadowCoord = input.shadowCoord;
#else
	inputData.shadowCoord = float4(0, 0, 0, 0);
#endif

	inputData.fogCoord = input.fogFactorAndVertexLight.x;
	inputData.vertexLighting = input.fogFactorAndVertexLight.yzw;
	inputData.bakedGI = SAMPLE_GI(input.lightmapUV, input.vertexSH, inputData.normalWS);

	// Modify By vanCopper  
#if defined(LIGHTMAP_ON) && defined(SHADOWS_SHADOWMASK)
	//inputData.shadowMask = SolarLandLightmap(input.lightmapUV, inputData.normalWS);
	inputData.bakedAtten = SampleShadowMask(input.lightmapUV);
	//#else
	//    inputData.shadowMask = 1;
#endif

}

///////////////////////////////////////////////////////////////////////////////
//                  Vertex and Fragment functions                            //
///////////////////////////////////////////////////////////////////////////////

// Used in Standard (Physically Based) shader
Varyings LitPassVertex(Attributes input)
{
	Varyings output = (Varyings)0;

	UNITY_SETUP_INSTANCE_ID(input);
	UNITY_TRANSFER_INSTANCE_ID(input, output);
	UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

	VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
	VertexNormalInputs normalInput = GetVertexNormalInputs(input.normalOS, input.tangentOS);
	half3 viewDirWS = GetCameraPositionWS() - vertexInput.positionWS;
	half3 vertexLight = VertexLighting(vertexInput.positionWS, normalInput.normalWS);
	half fogFactor = ComputeFogFactor(vertexInput.positionCS.z);

	output.uv = TRANSFORM_TEX(input.texcoord, _BaseMap);


	//Set up Normal Tangent and Bitangent in WorldSpace
	output.normalWS = half4(normalInput.normalWS, viewDirWS.x);
	output.tangentWS = half4(normalInput.tangentWS, viewDirWS.y);
	output.bitangentWS = half4(normalInput.bitangentWS, viewDirWS.z);


	OUTPUT_LIGHTMAP_UV(input.lightmapUV, unity_LightmapST, output.lightmapUV);
	OUTPUT_SH(output.normalWS.xyz, output.vertexSH);

	output.fogFactorAndVertexLight = half4(fogFactor, vertexLight);

#ifdef _ADDITIONAL_LIGHTS
	output.positionWS = vertexInput.positionWS;
#endif

#if defined(_MAIN_LIGHT_SHADOWS) && !defined(_RECEIVE_SHADOWS_OFF)
	output.shadowCoord = GetShadowCoord(vertexInput);
#endif

	output.positionCS = vertexInput.positionCS;

	return output;
}


half4 LitPassFragment(Varyings input) : SV_Target
{
	UNITY_SETUP_INSTANCE_ID(input);
	UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

	SurfaceData surfaceData;
	//Alpha
	//Albedo
	//Metallic
	//Specular
	//Smoothness
	//Normal-Mapping
	//occlution
	//emission
	InitializeStandardLitSurfaceData(input.uv, surfaceData);

	InputData inputData;
	InitializeInputData(input, surfaceData.normalTS, inputData);

	half anisotropy = Anisotropy(input.uv);

	half3x3 vectorsWS = GeometryTBN(input.uv,input.tangentWS.xyz, input.bitangentWS.xyz, input.normalWS.xyz);


	half4 color = LWRP_AnisotropicBRDF(inputData, surfaceData.albedo, surfaceData.metallic, surfaceData.specular, surfaceData.smoothness,
									   surfaceData.occlusion, surfaceData.emission, surfaceData.alpha, anisotropy, vectorsWS[0], vectorsWS[1]);

	color.rgb = MixFog(color.rgb, inputData.fogCoord);
	return color;
}

#endif
