"""Text-to-image on the ComfyUI server (Juggernaut XL + hires pass).

Usage: python3 generate.py <count> <outdir>
"""
import json, os, sys, time, urllib.request, uuid, random
B=os.environ.get("COMFYUI_URL","https://comfyui.wizh.it")
POS=("candid photograph of an elegant young woman in her twenties seated at a candlelit table in a fine-dining restaurant, "
 "wearing a deep purple silk evening gown and a regal amethyst and diamond necklace with matching drop earrings, "
 "gracefully raising a crystal champagne flute filled with sparkling white wine to just below her lips, about to take a sip, slight smile, closed lips, "
 "the flute is a classic thin-walled glass with a short slender stem, clear rim, fine bubbles rising, her fingers delicately holding the stem, "
 "on the white tablecloth an elegant plated dish of seared scallops with microgreens, silver cutlery, a small bread plate, "
 "warm ambient light, soft bokeh of chandeliers in the background, "
 "shot on Canon EOS R5, 85mm f/1.8, shallow depth of field, natural skin texture, subtle film grain, editorial photography")
NEG=("cartoon, illustration, painting, 3d render, cgi, anime, airbrushed skin, plastic skin, oversaturated, overexposed, "
 "tumbler, mug, coupe, distorted glass, warped glass, broken glass, glass merging with face, overly long stem, open mouth, teeth, deformed lips, straw, extra fingers, deformed hands, fused fingers, bad anatomy, cross-eyed, "
 "blurry, lowres, jpeg artifacts, text, watermark, logo, signature")
def wf(seed, hires=True):
    g={
     "4":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"juggernautXL_ragnarok.safetensors"}},
     "6":{"class_type":"CLIPTextEncode","inputs":{"text":POS,"clip":["4",1]}},
     "7":{"class_type":"CLIPTextEncode","inputs":{"text":NEG,"clip":["4",1]}},
     "5":{"class_type":"EmptyLatentImage","inputs":{"width":832,"height":1216,"batch_size":1}},
     "3":{"class_type":"KSampler","inputs":{"seed":seed,"steps":32,"cfg":4.5,"sampler_name":"dpmpp_2m_sde","scheduler":"karras","denoise":1.0,
          "model":["4",0],"positive":["6",0],"negative":["7",0],"latent_image":["5",0]}},
    }
    last="3"
    if hires:
        g["10"]={"class_type":"LatentUpscaleBy","inputs":{"upscale_method":"bislerp","scale_by":1.5,"samples":["3",0]}}
        g["11"]={"class_type":"KSampler","inputs":{"seed":seed,"steps":20,"cfg":4.5,"sampler_name":"dpmpp_2m_sde","scheduler":"karras","denoise":0.42,
          "model":["4",0],"positive":["6",0],"negative":["7",0],"latent_image":["10",0]}}
        last="11"
    g["8"]={"class_type":"VAEDecode","inputs":{"samples":[last,0],"vae":["4",2]}}
    g["9"]={"class_type":"SaveImage","inputs":{"filename_prefix":"improved/v3","images":["8",0]}}
    return g
def post(p):
    r=urllib.request.urlopen(urllib.request.Request(B+"/prompt",json.dumps({"prompt":p,"client_id":str(uuid.uuid4())}).encode(),{"Content-Type":"application/json"}))
    return json.load(r)["prompt_id"]
n=int(sys.argv[1]); out=sys.argv[2]; os.makedirs(out, exist_ok=True)
ids=[(s,post(wf(s))) for s in [random.randrange(1<<48) for _ in range(n)]]
for s,pid in ids:
    while True:
        h=json.load(urllib.request.urlopen(f"{B}/history/{pid}"))
        if pid in h: break
        time.sleep(3)
    for o in h[pid]["outputs"].values():
        for im in o["images"]:
            fn=f"{out}/{s}.png"
            urllib.request.urlretrieve(f"{B}/view?filename={im['filename']}&subfolder={im['subfolder']}&type=output",fn)
            print(s, im['subfolder']+'/'+im['filename'], fn)
