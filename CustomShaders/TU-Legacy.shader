Shader "TU/Legacy"
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
		_SpecGlossNormMask("_SpecGlossNormMask", 2D) = "black" {}
		_SpecGlossInputMask("_SpecGlossInputMask", 2D) = "white" {}
		
		//detail textures -- diff/met/nrm??
		
		//standard shader params
		_Color ("_Color", Color) = (1,1,1)
		_GlossColor ("_GlossColor", Color) = (1,1,1)
		_Smoothness ("_Smoothness", Range(0,1)) = 1
		
		//recoloring input color values
		_MaskColor1 ("Mask Color 1", Color) = (1,1,1,1)
		_MaskColor2 ("Mask Color 2", Color) = (1,1,1,1)
		_MaskColor3 ("Mask Color 3", Color) = (1,1,1,1)
		_MaskMetallic ("Mask Metals", Vector) = (0,0,0,0)
		
		//recoloring normalization params -- diffuse in R, Specular in G, smooth in B
		_Channel1Norm ("Mask Channel 1 Normallization", Vector) = (0,0,0,0)
		_Channel2Norm ("Mask Channel 2 Normallization", Vector) = (0,0,0,0)
		_Channel3Norm ("Mask Channel 3 Normallization", Vector) = (0,0,0,0)
		
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
		#pragma surface surf TUColored keepalpha
		#pragma target 3.0
		//#pragma skip_variants POINT POINT_COOKIE DIRECTIONAL_COOKIE //need to find out what variants are -actually- used...
		//#pragma multi_compile_fwdadd_fullshadows //stalls out Unity Editor while compiling shader....
		#pragma multi_compile __ TU_SUBSURF
		#pragma multi_compile TU_STD_SPEC TU_STOCK_SPEC
		#pragma multi_compile TU_RECOLOR_OFF TU_RECOLOR_STANDARD
		#pragma multi_compile __ TU_RECOLOR_NORM TU_RECOLOR_INPUT TU_RECOLOR_NORM_INPUT
		
		#include "Lighting.cginc"
		#include "SSTUShaders.cginc"
		
		//Texture samplers for all possible texture slots
		//TODO -- block out unused samplers by keyword
		sampler2D _MainTex;
		sampler2D _SpecGlossMap;
		sampler2D _BumpMap;
		sampler2D _AOMap;
		sampler2D _Emissive;
		sampler2D _Thickness;
		
		sampler2D _MaskTex;
		sampler2D _SpecGlossNormMask;
		sampler2D _SpecGlossInputMask;
		
		//standard shader params for adjusting color/etc
		float3 _Color;
		float3 _GlossColor;
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
		
		float4 _Channel1Norm;
		float4 _Channel2Norm;
		float4 _Channel3Norm;
		
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
            fixed3 Albedo;
			fixed3 Normal;
			half3 Emission;
			half Smoothness;
			half3 SpecularColor;
			half Occlusion;
            fixed Alpha;
			half4 Backlight;
        };
		
		//custom lighting function to enable SubSurf functionality
		inline half4 LightingTUColored(SurfaceOutputTU s, half3 lightDir, half3 viewDir, half atten)
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
				
				float3 H = normalize(lightDir + s.Normal * fLTDistortion);
				float vdh = pow(saturate(dot(viewDir, -H)), iLTPower) * fLTScale;
				float3 I = fLightAttenuation * (vdh + fLTAmbient) * fLTThickness;
				half3 backColor = I * _LightColor0.rgb;
			#endif

			
			s.Smoothness = max(0.01, s.Smoothness);
			//standard blinn-phong lighting model
			//diffuse light intensity, from surface normal and light direction
			half diff = max (0, dot (s.Normal, lightDir));
			//specular light calculations
			half3 h = normalize (lightDir + viewDir);
			float nh = max (0, dot (s.Normal, h));
			float spec = pow (nh, s.Smoothness * 128);
			half3 specCol = spec * s.SpecularColor;
			
			//output fragment color; Unity adds Emission to it through some other method
			half4 c;
			c.rgb = ((s.Albedo * _LightColor0.rgb * diff + _LightColor0.rgb * specCol)) * atten;
			c.a = s.Alpha;
			
			#if TU_SUBSURF
				c.rgb += backColor;
			#endif			
			
			return c;
		}
		
		void surf (Input IN, inout SurfaceOutputTU o)
		{
			//standard texture samplers used regardless of keywords...
			fixed4 color = tex2D(_MainTex,(IN.uv_MainTex));
			fixed4 specSample = tex2D(_SpecGlossMap, (IN.uv_MainTex));
			
			fixed3 glossColor = specSample.rgb;
			
			#if TU_STD_SPEC
				fixed smooth = specSample.a;
			#endif
			#if TU_STOCK_SPEC
				fixed smooth = color.a;
			#endif
						
			//new TU recolor mode based on normalization maps
			#if TU_RECOLOR_STANDARD
			
				//RGBA value from the mask; RGB = recoloring channels, A = diffuse luminance normalization data
				fixed4 mask = tex2D(_MaskTex, (IN.uv_MainTex));
				fixed diffuseNorm = mask.a + getUserValue(mask, _Channel1Norm.x, _Channel2Norm.x, _Channel3Norm.x);
				fixed glossNorm = getUserValue(mask, _Channel1Norm.y, _Channel2Norm.y, _Channel3Norm.y);
				fixed smoothNorm = getUserValue(mask, _Channel1Norm.z, _Channel2Norm.z, _Channel3Norm.z);
				
				//same for specular and metallic if normalization for those channels is enabled
				#if TU_RECOLOR_NORM || TU_RECOLOR_NORM_INPUT
					fixed4 specMetNormData = tex2D(_SpecGlossNormMask, (IN.uv_MainTex));
					glossNorm += specMetNormData.r;
					smoothNorm += specMetNormData.a;
				#endif
				
				fixed glossMaskFactor = 1;
				fixed specMaskFactor = 1;
				
				//sample/calculate mix factors for user-specified spec and metal values if input-masking setting is enabled
				#if TU_RECOLOR_INPUT || TU_RECOLOR_NORM_INPUT
					fixed4 specMaskValues = tex2D(_SpecGlossInputMask, IN.uv_MainTex);
					glossMaskFactor = specMaskValues.r;
					specMaskFactor = specMaskValues.a;
				#endif
				
				fixed3 custSpec;
				o.Albedo = recolorStandardSpecularToMetallic(color.rgb, glossColor.rgb, mask, _MaskMetallic, diffuseNorm, glossNorm, glossMaskFactor, _MaskColor1.rgb, _MaskColor2.rgb, _MaskColor3.rgb, custSpec);
				o.SpecularColor = custSpec;
				
				// o.Albedo = recolorStandard(color.rgb, mask, diffuseNorm, _MaskColor1.rgb, _MaskColor2.rgb, _MaskColor3.rgb);				
				//o.SpecularColor = recolorStandard(glossColor, mask * glossMaskFactor, glossNorm, _MaskSpec1.rgb, _MaskSpec2.rgb, _MaskSpec3.rgb);
				o.Smoothness = recolorStandard(smooth, mask * specMaskFactor, smoothNorm, _MaskColor1.a, _MaskColor2.a, _MaskColor3.a);
				
			#endif
			
			//no recoloring enabled -- use standard texture sampling -- use the values directly from the source textures
			#if TU_RECOLOR_OFF
				o.Albedo = color.rgb;
				o.Smoothness = smooth;
				o.SpecularColor = glossColor;
			#endif
			
			//If subsurf is enabled, this is a bit of pre-setup to pass params to lighting function
			#if TU_SUBSURF
				fixed4 thick = tex2D(_Thickness, (IN.uv_MainTex));
				o.Backlight.rgb = thick.rgb;
				//TODO -- can sample property in lighting function; no need to pass through alpha channel, save a register
				o.Backlight.a = _SubSurfAmbient;
			#endif
			
			fixed3 normal = UnpackNormal(tex2D(_BumpMap, IN.uv_MainTex));
			o.Normal = normal;
			
			fixed4 ao = tex2D(_AOMap, (IN.uv_MainTex));
			o.Occlusion = ao.r;
			
			fixed4 glow = tex2D(_Emissive, (IN.uv_MainTex));
			o.Emission = glow.rgb * glow.aaa * _EmissiveColor.rgb *_EmissiveColor.aaa + stockEmit(IN.viewDir, normal, _RimColor, _RimFalloff, _TemperatureColor) * _Opacity;
			
			o.Alpha = _Opacity;
			
			//apply the standard shader param multipliers to the sampled/computed values.
			o.Albedo *= _Color.rgb;
			o.Smoothness *= _Smoothness;
			o.SpecularColor *= _GlossColor;
		}
		
		ENDCG
	}
	Fallback "Standard"
	CustomEditor "TUMetallicUI"
}