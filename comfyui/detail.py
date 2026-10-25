"""Face/glass detail pass: crop a region, re-render it at 2x, blend it back.

Usage: python3 detail.py <image.png> <x> <y> <w> <h> <denoise> <out.png>
"""
import json, sys, time, urllib.request, uuid, os
B=os.environ.get("COMFYUI_URL","https://comfyui.wizh.it")
src,x,y,w,h,den,out=sys.argv[1],*map(int,sys.argv[2:6]),float(sys.argv[6]),sys.argv[7]
# upload
bnd=uuid.uuid4().hex; data=open(src,'rb').read(); name="detail_src_"+os.path.basename(src)
body=(f"--{bnd}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"{name}\"\r\nContent-Type: image/png\r\n\r\n").encode()+data+f"\r\n--{bnd}\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n--{bnd}--\r\n".encode()
up=json.load(urllib.request.urlopen(urllib.request.Request(B+"/upload/image",body,{"Content-Type":f"multipart/form-data; boundary={bnd}"})))
POS=("close-up photograph of a beautiful young woman's face, sharp detailed eyes, natural skin texture with pores, soft closed lips with natural lip lines, slight smile, "
 "holding a crystal champagne flute with sparkling white wine, thin clean glass rim, crisp reflections and refraction, fine rising bubbles, "
 "elegant fingers, diamond and amethyst earrings, warm candlelight, 85mm portrait, editorial photography")
NEG=("deformed lips, blurry mouth, asymmetric eyes, distorted glass, warped glass, plastic skin, airbrushed, extra fingers, cartoon, 3d render, oversaturated, lowres, text, watermark")
S=2
g={
 "1":{"class_type":"LoadImage","inputs":{"image":up["name"]}},
 "4":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"juggernautXL_ragnarok.safetensors"}},
 "6":{"class_type":"CLIPTextEncode","inputs":{"text":POS,"clip":["4",1]}},
 "7":{"class_type":"CLIPTextEncode","inputs":{"text":NEG,"clip":["4",1]}},
 "20":{"class_type":"ImageCrop","inputs":{"image":["1",0],"width":w,"height":h,"x":x,"y":y}},
 "21":{"class_type":"ImageScale","inputs":{"image":["20",0],"upscale_method":"lanczos","width":w*S,"height":h*S,"crop":"disabled"}},
 "22":{"class_type":"VAEEncode","inputs":{"pixels":["21",0],"vae":["4",2]}},
 "23":{"class_type":"KSampler","inputs":{"seed":12345,"steps":30,"cfg":4.0,"sampler_name":"dpmpp_2m_sde","scheduler":"karras","denoise":den,
       "model":["4",0],"positive":["6",0],"negative":["7",0],"latent_image":["22",0]}},
 "24":{"class_type":"VAEDecode","inputs":{"samples":["23",0],"vae":["4",2]}},
 "25":{"class_type":"ImageScale","inputs":{"image":["24",0],"upscale_method":"lanczos","width":w,"height":h,"crop":"disabled"}},
 "26":{"class_type":"SolidMask","inputs":{"value":1.0,"width":w,"height":h}},
 "27":{"class_type":"FeatherMask","inputs":{"mask":["26",0],"left":48,"top":48,"right":48,"bottom":48}},
 "28":{"class_type":"ImageCompositeMasked","inputs":{"destination":["1",0],"source":["25",0],"x":x,"y":y,"resize_source":False,"mask":["27",0]}},
 "9":{"class_type":"SaveImage","inputs":{"filename_prefix":"improved/detail","images":["28",0]}},
}
pid=json.load(urllib.request.urlopen(urllib.request.Request(B+"/prompt",json.dumps({"prompt":g}).encode(),{"Content-Type":"application/json"})))["prompt_id"]
while True:
    hh=json.load(urllib.request.urlopen(f"{B}/history/{pid}"))
    if pid in hh: break
    time.sleep(3)
if hh[pid]['status']['status_str']!='success': print(json.dumps(hh[pid]['status'])[:2000]); sys.exit(1)
for o in hh[pid]["outputs"].values():
    for im in o["images"]:
        urllib.request.urlretrieve(f"{B}/view?filename={im['filename']}&subfolder={im['subfolder']}&type=output",out); print(im['subfolder']+'/'+im['filename'],out)
