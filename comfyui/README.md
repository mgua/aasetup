# ComfyUI prompt work — "lady with champagne" image

Server: https://comfyui.wizh.it (ComfyUI v0.3.7, Windows portable, Quadro RTX 8000 48 GB).
Checkpoints available: `juggernautXL_ragnarok`, `realvisxlV50_v50LightningBakedvae`,
`sdvn7Nijistylexl_v1`. No Impact Pack / FaceDetailer, no upscale models.

Original prompt:

> a photorealistic picture of a beautiful young woman wearing regal jewelry and an elegant
> purple dress, drinking sparkling white from a high glass, in a sophisticated restaurant,
> with food on the table

## What was wrong (ComfyUI_00084–00088)

- CFG 8 + euler/normal → oversaturated, plastic "AI render" look.
- Glass touching the lips → rim melts into the mouth, warped bowls, absurdly long stems.
- 1024×1024 square crop is poor for a seated portrait; food came out as vague blobs.

## What fixed it

1. Pose: glass raised to just *below* the lips ("about to take a sip"), closed lips.
   SDXL cannot reliably render glass pressed against lips.
2. Settings: 832×1216, `dpmpp_2m_sde` + `karras`, 32 steps, CFG 4.5,
   then latent upscale ×1.5 (bislerp) + second pass at denoise 0.42.
3. Detail pass (`detail.py`): crop face+glass, render at 2× with denoise ~0.38,
   feather-composite back. Core nodes only.

Best result on the server: `output/improved/detail_00001_.png`
(from `improved/v3_00002_.png`, crop x=440 y=400 w=640 h=768).

```
python3 generate.py 4 out/            # COMFYUI_URL overrides the server
python3 detail.py out/<seed>.png 440 400 640 768 0.38 out/detail.png
```

## SDXL / ComfyUI prompt (hands, natural pose, about to drink, smiling)

Positive:

```
candid editorial photograph of an elegant young woman in her twenties seated at a candlelit table in a fine-dining restaurant, relaxed natural posture, shoulders soft, head slightly tilted, warm genuine smile, closed lips, eyes looking toward the camera,
she gracefully raises a crystal champagne flute of sparkling white wine near her chin, about to take a sip, holding the glass by its stem with relaxed slender fingers, her other hand resting gently on the white tablecloth,
deep purple silk evening gown, regal amethyst and diamond necklace with matching drop earrings,
on the table a plated dish of seared scallops with microgreens, polished silver cutlery,
warm candlelight, soft bokeh of crystal chandeliers in the background,
shot on Canon EOS R5, 85mm f/1.8, shallow depth of field, natural skin texture, subtle film grain
```

Negative:

```
deformed hands, malformed hands, extra fingers, missing fingers, fused fingers, too many fingers, long fingers, twisted wrist, extra arms, extra hands, claw hands,
stiff pose, awkward pose, mannequin, exaggerated smile, open mouth, teeth, deformed lips,
distorted glass, warped glass, glass merging with face, overly long stem, tumbler, mug,
cartoon, illustration, 3d render, cgi, airbrushed skin, plastic skin, oversaturated,
blurry, lowres, jpeg artifacts, text, watermark, logo
```

Give each hand one simple, common job (holding the stem / resting on the table);
run 4–6 seeds and keep the best; fix a stray hand with the crop detail pass.

## Nano Banana (Gemini) prompt

No negative field: write exclusions as sentences; fix flaws with follow-up edit requests.

```
A photorealistic editorial photograph of an elegant young woman in her twenties, seated at a candlelit table in a sophisticated fine-dining restaurant. She has a relaxed, natural posture with soft shoulders and her head tilted slightly, and she gives the camera a warm, genuine smile with closed lips.

With her right hand she gracefully raises a crystal champagne flute of sparkling white wine to just below her chin, as if about to take a sip. She holds the glass by its slender stem between her thumb and fingers in a light, relaxed grip. Her left hand rests gently on the white tablecloth. Both hands are anatomically correct and natural, with five well-proportioned fingers each. The flute is a classic thin-walled glass with a clean rim, fine bubbles rising, and realistic reflections. It does not touch her lips.

She wears a deep purple silk evening gown and regal jewelry: an amethyst and diamond necklace with matching drop earrings. On the table in front of her are a beautifully plated dish of seared scallops with microgreens and polished silver cutlery.

The lighting is warm, soft candlelight, with crystal chandeliers glowing as soft bokeh in the background. Shot on a full-frame camera with an 85mm lens at f/1.8, shallow depth of field, natural skin texture, subtle film grain. Vertical 2:3 composition, framed from the waist up.
```

Follow-up edit example: *"Fix her right hand so she holds the flute stem naturally with
relaxed fingers; keep everything else identical."*
