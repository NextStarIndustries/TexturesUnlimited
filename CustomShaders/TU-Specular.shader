Shader "TU/Specular"
{
	Properties 
	{
		//standard texture input slots
		_MainTex("_MainTex (RGB)", 2D) = "white" {}
		_SpecGlossMap("_SpecGlossMap (RGBA)", 2D) = "white" {}
		_BumpMap("_BumpMap (NRM)", 2D) = "bump" {}
		_AOMap("_AOMap (Grayscale)", 2D) = "white" {}
		_Emissive("_Emission (RGB Emissive Map)", 2D) = "black" {}
		_Thickness("_Thickness (RGB Subsurf Thickness) ", 2D) = "white" {}
		
		//recoloring texture input slots
		_MaskTex("_MaskTex (RGB Color Mask)", 2D) = "black" {}
		_MetalGlossNormMask("_MetalGlossNormMask", 2D) = "black" {}
		_MetalGlossInputMask("_MetalGlossInputMask", 2D) = "white" {}
				
		//standard shader params
		_Color ("_Color", Color) = (1,1,1)
		_SpecularColor ("_SpecColor", Color) = (1,1,1)
		_Smoothness ("_Smoothness", Range(0,1)) = 1
		
		//recoloring input color values
		_MaskColor1 ("Mask Color 1", Color) = (1,1,1,1)
		_MaskColor2 ("Mask Color 2", Color) = (1,1,1,1)
		_MaskColor3 ("Mask Color 3", Color) = (1,1,1,1)
		_MaskMetallic ("Mask Metals", Vector) = (0,0,0,0)
		
		//sub-surface scattering shader parameters		
		_SubSurfAmbient("SubSurf Ambient", Range(0, 1)) = 0
		_SubSurfScale("SubSurf Scale", Range(0, 10)) = 1
		_SubSurfPower("SubSurf Falloff Power", Range(0, 10)) = 1
		_SubSurfDistort("SubSurf Distortion", Range(0, 1)) = 0
		_SubSurfAtten("SubSurf Attenuation", Range(0, 1)) = 1
		
		//stock KSP compatibility properties -- used for emission/glow, part-highlighting, part-thermal overlay, and part 'burn' discoloring
		_EmissiveColor("EmissionColor", Color) = (0,0,0)
		_Opacity("Part Opacity", Range(0,1) ) = 1
		_RimFalloff("_RimFalloff", Range(0.01,5) ) = 0.1
		_RimColor("_RimColor", Color) = (0,0,0,0)
		_TemperatureColor("Temperature Color", Color) = (0,0,0,0)
		_BurnColor ("Burn Color", Color) = (1,1,1,1)
	}
	
	SubShader
	{
		Tags {"RenderType"="Opaque"}
		ZWrite On
		ZTest LEqual
		Blend SrcAlpha OneMinusSrcAlpha

		CGPROGRAM

		//directives for 'surface shader' 'surface name = 'TU'' and 'don't discard alpha values'
		#pragma surface surf TU keepalpha
		#pragma target 3.0
		//#pragma skip_variants POINT POINT_COOKIE DIRECTIONAL_COOKIE //need to find out what variants are -actually- used...
		//#pragma multi_compile_fwdadd_fullshadows //stalls out Unity Editor while compiling shader....
		// #pragma multi_compile __ TU_EMISSIVE
		// #pragma multi_compile __ TU_BUMPMAP		
		// #pragma multi_compile __ TU_SUBSURF
		// #pragma multi_compile __ TU_AOMAP
		// #pragma multi_compile __ TU_STOCK_SPEC
		// #pragma multi_compile TU_RECOLOR_OFF TU_RECOLOR_STANDARD TU_RECOLOR_LEGACY TU_RECOLOR_TINTING
		// #pragma multi_compile __ TU_RECOLOR_NORM
		// #pragma multi_compile __ TU_RECOLOR_INPUT
		
		#include "HLSLSupport.cginc"
		#include "UnityCG.cginc"
		#include "Lighting.cginc"
		#include "AutoLight.cginc"
		#include "UnityPBSLighting.cginc"
		#include "SSTUShaders.cginc"
		
		//Texture samplers for all possible texture slots
		//TODO -- block out unused samplers by keyword
		sampler2D _MainTex;
		sampler2D _MetallicGlossMap;
		sampler2D _BumpMap;
		sampler2D _AOMap;
		sampler2D _Emissive;
		sampler2D _Thickness;
		
		sampler2D _MaskTex;
		sampler2D _MetalGlossNormMask;
		sampler2D _MetalGlossInputMask;
		
		//standard shader params for adjusting color/etc
		float3 _Color;
		float3 _SpecularColor;
		float _Smoothness;

		//standard KSP shader property values
		float _Opacity;
		float4 _EmissiveColor;
		float4 _TemperatureColor;
		float4 _RimColor;
		float _RimFalloff;
		
		//recoloring property values
		float4 _MaskColor1;
		float4 _MaskColor2;
		float4 _MaskColor3;
		float4 _MaskMetallic;
		
		//subsurf property values
		float _SubSurfAmbient;
		float _SubSurfScale;
		float _SubSurfPower;
		float _SubSurfDistort;
		float _SubSurfAtten;
		
		//basic trimmed-down input struct with only UVs for main texture and view direction; absolute minimum needed
		//TODO -- add UV coords for other samplers, hopefully blocked off by function
		//will need at least uv scaling/offset for the detail-texture feature
		struct Input
		{
			float2 uv_MainTex;
			float3 viewDir;
		};
		
		//custom surface output struct used to enable subsurf lighting params
		struct SurfaceOutputTU
        {
            fixed3 Albedo;		// base (diffuse or specSampleular) color
			fixed3 Normal;		// tangent space normal, if written
			half3 Emission;		// emissive / glow color
            half3 Specular;		// 0=non-metal, 1=metal
            half Smoothness;	// 0=rough, 1=smooth
			half Occlusion;		// occlusion (default 1)
            fixed Alpha;		// alpha for transparencies
			half4 Backlight;	// backlight emissive glow color(RGB) and ambient light value (A)
			half4 SubSurfParams;// subsurface scattering parameters R = Scale, G = Power, B = Scale, A = Attenuation
        };
		
		//replacement for Unity bridge method to call GI with custom structs
		inline void LightingTU_GI (SurfaceOutputTU s, UnityGIInput data, inout UnityGI gi)
		{
			UNITY_GI(gi, s, data);
		}	

		//custom lighting function to enable SubSurf functionality
		inline half4 LightingTU(SurfaceOutputTU s, half3 viewDir, UnityGI gi)
		{
			#if TU_BUMPMAP
				s.Normal = normalize(s.Normal);
			#endif
			
			#if TU_SUBSURF
				//SSS implementation from:  https://colinbarrebrisebois.com/2011/03/07/gdc-2011-approximating-translucency-for-a-fast-cheap-and-convincing-subsurface-scattering-look/	
				
				half fLTScale = _SubSurfScale;//main output scalar
				half iLTPower = _SubSurfPower;//exponent used in power
				half fLTDistortion = _SubSurfDistort;;//how much the surface normal distorts the outgoing light
				half fLightAttenuation = _SubSurfAtten;//how much light attenuates while traveling through the surface (gets multiplied by distance)  
				
				//half fLTScale = s.SubSurfParams.r;//main output scalar
				//half iLTPower = s.SubSurfParams.g;//exponent used in power
				//half fLTDistortion = s.SubSurfParams.b;//how much the surface normal distorts the outgoing light
				//half fLightAttenuation = s.SubSurfParams.a;//how much light attenuates while traveling through the surface (gets multiplied by distance)
				
				half fLTAmbient = s.Backlight.a;//ambient from texture/material
				half3 fLTThickness = s.Backlight.rgb;//sampled from texture
				
				float3 H = normalize(gi.light.dir + s.Normal * fLTDistortion);
				float vdh = pow(saturate(dot(viewDir, -H)), iLTPower) * fLTScale;
				float3 I = fLightAttenuation * (vdh + fLTAmbient) * fLTThickness;
				half3 backColor = I * gi.light.color;
			#endif
			
			//Unity 'Standard' lighting function, unabridged
			// energy conservation
			half oneMinusReflectivity;
			s.Albedo = EnergyConservationBetweenDiffuseAndSpecular (s.Albedo, s.Specular, /*out*/ oneMinusReflectivity);
			// shader relies on pre-multiply alpha-blend (_SrcBlend = One, _DstBlend = OneMinusSrcAlpha)
			// this is necessary to handle transparency in physically correct way - only diffuse component gets affected by alpha
			half outputAlpha;
			s.Albedo = PreMultiplyAlpha (s.Albedo, s.Alpha, oneMinusReflectivity, /*out*/ outputAlpha);
			half4 c = UNITY_BRDF_PBS (s.Albedo, s.Specular, oneMinusReflectivity, s.Smoothness, s.Normal, viewDir, gi.light, gi.indirect);
			c.rgb += UNITY_BRDF_GI (s.Albedo, s.Specular, oneMinusReflectivity, s.Smoothness, s.Normal, viewDir, s.Occlusion, gi);
			c.a = outputAlpha;
			
			#if TU_SUBSURF
				c.rgb += backColor;
			#endif
			
			return c;
		}
		
		void surf (Input IN, inout SurfaceOutputTU o)
		{
			//standard texture samplers used regardless of keywords...
			fixed4 color = tex2D(_MainTex,(IN.uv_MainTex));
			fixed4 specSample = tex2D(_MetallicGlossMap, (IN.uv_MainTex));
			
			//metal ALWAYS comes from MetallicGlossMap.r channel
			fixed metal = specSample.r;
			
			//if 'stock specular' mode is enabled, pull spec value from alpha channel of diffuse shader
			//else pull it from the alpha channel of the metallic gloss map
			#if TU_STOCK_SPEC
				fixed smooth = color.a;
			#else
				fixed smooth = specSample.a;
			#endif
			
			//if bump-map enabled, sample texture; else assign default NRM
			#if TU_BUMPMAP
				fixed3 normal = UnpackNormal(tex2D(_BumpMap, IN.uv_MainTex));
				o.Normal = normal;
			#else
				fixed3 normal = fixed3(0,0,1);
			#endif
			
			//new TU recolor mode based on normalization maps
			#if TU_RECOLOR_STANDARD
			
				//RGBA value from the mask; RGB = recoloring channels, A = diffuse luminance normalization data
				fixed4 mask = tex2D(_MaskTex, (IN.uv_MainTex));
				
				fixed diffMaskFactor = saturate(1 - (mask.r + mask.g + mask.b));//mixing factor between original source texture and user-specified value for diffuse channel
				
				//sample/calculate mix factors for user-specified spec and metal values if input-masking setting is enabled
				#if TU_RECOLOR_INPUT				
					fixed4 specMaskValues = tex2D(_MetalGlossInputMask, IN.uv_MainTex);
					fixed specMaskFactor = diffMaskFactor * (1 - specMaskValues.a);
					fixed metalMaskFactor = diffMaskFactor * (1 - specMaskValues.r);
				#else
					fixed specMaskFactor = diffMaskFactor;
					fixed metalMaskFactor = diffMaskFactor;
				#endif
				
				fixed3 userColor = saturate(mask.rrr * _MaskColor1.rgb + mask.ggg * _MaskColor2.rgb + mask.bbb * _MaskColor3.rgb);
				fixed userSpecSample = mask.r * _MaskColor1.a + mask.g * _MaskColor2.a + mask.b * _MaskColor3.a;
				fixed userMetallic = mask.r * _MaskMetallic.r + mask.g * _MaskMetallic.g + mask.b * _MaskMetallic.b;
				
				//convert original diffuse to luminance value
				fixed originalTexLuminance = Luminance(color.rgb);				
				//add the resultant grayscale detail onto the user-selected color for this pixel
				userColor.rgb += originalTexLuminance;
				//subtract normalization data from alpha channel of mask texture
				userColor.rgb -= mask.a;
				
				//same for specular and metallic if normalization for those channels is enabled
				#if TU_RECOLOR_NORM
					fixed4 specMetNormData = tex2D(_MetalGlossNormMask, (IN.uv_MainTex));
					userMetallic += metal;
					userMetallic -= specMetNormData.r;
					userSpecSample += smooth;
					userSpecSample -= specMetNormData.a;
				#else
					//noop?
					//change from add to mult?
					userSpecSample += smooth;					
					userMetallic += metal;
				#endif
				
				o.Albedo = mix3(userColor, color, diffMaskFactor);
				o.Smoothness = mix1(userSpecSample, smooth, specMaskFactor);
				o.Metallic = mix1(userMetallic, metal, metalMaskFactor);
				
			#endif
			//SSTU legacy recoloring mode (gray base textures)
			#if TU_RECOLOR_LEGACY
				fixed3 mask = tex2D(_MaskTex, (IN.uv_MainTex));
				fixed m = saturate(1 - (mask.r + mask.g + mask.b));
				fixed3 userColor = mask.rrr * _MaskColor1.rgb + mask.ggg * _MaskColor2.rgb + mask.bbb * _MaskColor3.rgb;
				fixed3 userSpecSample = mask.r * _MaskColor1.a + mask.g * _MaskColor2.a + mask.b * _MaskColor3.a;
				fixed userMetallic = mask.r * _MaskMetallic.r + mask.g * _MaskMetallic.g + mask.b * _MaskMetallic.b;
					
				fixed3 diffuseColor = color.rgb * m;
				fixed baseSpecSample = smooth * m;
				fixed baseMetallic = metal * m;
				fixed3 detailColor = (color.rgb - 0.5) * (1 - m);
				fixed3 detailspecSample = (specSample.rgb - 0.5) * (1 - m);
				fixed detailMetallic = (specSample.a - 0.5) * (1 - m);
				o.Albedo = saturate(userColor + diffuseColor + detailColor);
				o.Smoothness = saturate(userSpecSample + baseSpecSample + detailspecSample).r;
				o.Metallic = saturate(userMetallic + baseMetallic + detailMetallic);
			#endif
			//SSTU legacy tinting mode
			#if TU_RECOLOR_TINTING
				fixed3 mask = tex2D(_MaskTex, (IN.uv_MainTex));
				fixed m = saturate(1 - (mask.r + mask.g + mask.b));
				fixed3 userColor = mask.rrr * _MaskColor1.rgb + mask.ggg * _MaskColor2.rgb + mask.bbb * _MaskColor3.rgb;
				fixed3 userSpecSample = mask.r * _MaskColor1.a + mask.g * _MaskColor2.a + mask.b * _MaskColor3.a;
				fixed userMetallic = mask.r * _MaskMetallic.r + mask.g * _MaskMetallic.g + mask.b * _MaskMetallic.b;
					
				fixed3 diffuseColor = color.rgb * m;
				fixed baseSpecSample = smooth * m;
				fixed baseMetallic = metal * m;
				fixed3 detailColor = color.rgb * (1 - m);
				fixed3 detailspecSample = specSample.rgb * (1 - m);
				fixed detailMetallic = specSample.a * (1 - m);
				o.Albedo = saturate(userColor * detailColor + diffuseColor);
				o.Smoothness = saturate(userSpecSample * detailspecSample + baseSpecSample).r;
				o.Metallic = saturate(userMetallic * detailMetallic + baseMetallic);
			#endif
			//no recoloring enabled -- use standard texture sampling -- use the values directly from the source textures
			#if TU_RECOLOR_OFF
				o.Albedo = color.rgb;
				o.Smoothness = smooth;
				o.Metallic = metal;
			#endif
			
			//If subsurf is enabled, this is a bit of pre-setup to pass params to lighting function
			#if TU_SUBSURF
				fixed4 thick = tex2D(_Thickness, (IN.uv_MainTex));
				o.Backlight.rgb = thick.rgb;
				//TODO -- can sample property in lighting function; no need to pass through alpha channel, save a register
				o.Backlight.a = _SubSurfAmbient;
			#endif
			
			//only sample and apply AO map if AO is enabled
			#if TU_AOMAP
				fixed4 ao = tex2D(_AOMap, (IN.uv_MainTex));
				o.Occlusion = ao.r;
			#else
				o.Occlusion = 1;
			#endif
			
			//only sample and apply value from emissive map and color if emission is enabled
			//else only apply stock part-highlighting emissive functionality
			#if TU_EMISSIVE
				fixed4 glow = tex2D(_Emissive, (IN.uv_MainTex));
				o.Emission = glow.rgb * glow.aaa * _EmissiveColor.rgb *_EmissiveColor.aaa + stockEmit(IN.viewDir, normal, _RimColor, _RimFalloff, _TemperatureColor) * _Opacity;
			#else
				o.Emission = stockEmit(IN.viewDir, normal, _RimColor, _RimFalloff, _TemperatureColor) * _Opacity;
			#endif
			
			o.Alpha = _Opacity;
			
			//apply the standard shader param multipliers to the sampled/computed values.
			o.Albedo *= _Color;
			o.Specular *= _SpecularColor;
			o.Smoothness *= _Smoothness;			
		}
		
		ENDCG
	}
	Fallback "Standard"
	//CustomEditor "TUMetallicUI"
}