#!/usr/bin/env python3
"""
Script de procesamiento de animaciones para CapyTask.
Remueve el fondo oscuro preservando el contorno sticker blanco,
aplica un recorte uniforme y genera fotogramas PNG transparentes y GIFs optimizados.
"""

import os
import json
import numpy as np
from PIL import Image, ImageSequence
from scipy import ndimage

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW_DIR = os.path.join(BASE_DIR, "assets_raw")
OUT_DIR = os.path.join(BASE_DIR, "assets_processed")
FRAMES_DIR = os.path.join(OUT_DIR, "frames")

CONFIG = [
    {"raw": "capy_normal.gif", "state": "normal", "out_gif": "capy_normal.gif"},
    {"raw": "capy_worried.gif", "state": "worried", "out_gif": "capy_worried.gif"},
    {"raw": "capy_stressed.gif", "state": "stressed", "out_gif": "capy_stressed.gif"},
]

# Bounding box global unificado con margen de seguridad
# y=[87, 397], x=[15, 246] -> Tamaño: 232 x 311 px
CROP_YMIN = 87
CROP_YMAX = 397
CROP_XMIN = 15
CROP_XMAX = 246

def process_frame(frame: Image.Image) -> Image.Image:
    """Extrae el sticker del capibara y remueve el fondo oscuro."""
    arr = np.array(frame.convert("RGBA"))
    rgb = arr[:, :, :3]
    brightness = np.max(rgb, axis=2)
    
    # Máscara de primer plano (brillo > 50)
    fg = brightness > 50
    
    # Limpieza de ruido dither
    opened = ndimage.binary_opening(fg, structure=np.ones((3, 3)))
    labeled, num_features = ndimage.label(opened)
    
    if num_features == 0:
        # Fallback vacío transparente
        return Image.new("RGBA", (CROP_XMAX - CROP_XMIN + 1, CROP_YMAX - CROP_YMIN + 1), (0, 0, 0, 0))
    
    sizes = ndimage.sum(opened, labeled, range(1, num_features + 1))
    largest_label = np.argmax(sizes) + 1
    capy_mask = (labeled == largest_label)
    
    # Rellenar huecos interiores (ojos, boca, detalles)
    filled_mask = ndimage.binary_fill_holes(capy_mask)
    
    # Dilatación suave de 1px para borde antialias perfecto
    final_mask = ndimage.binary_dilation(filled_mask, structure=np.ones((3, 3)))
    
    result = arr.copy()
    result[:, :, 3] = (final_mask * 255).astype(np.uint8)
    
    # Recorte unificado
    cropped_arr = result[CROP_YMIN:CROP_YMAX + 1, CROP_XMIN:CROP_XMAX + 1]
    return Image.fromarray(cropped_arr, mode="RGBA")

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    metadata = {
        "width": CROP_XMAX - CROP_XMIN + 1,
        "height": CROP_YMAX - CROP_YMIN + 1,
        "states": {}
    }
    
    for item in CONFIG:
        raw_path = os.path.join(RAW_DIR, item["raw"])
        if not os.path.exists(raw_path):
            print(f"Advertencia: no se encontró {raw_path}")
            continue
        
        state_name = item["state"]
        state_dir = os.path.join(FRAMES_DIR, state_name)
        os.makedirs(state_dir, exist_ok=True)
        
        print(f"Procesando {item['raw']} ({state_name})...")
        im = Image.open(raw_path)
        
        processed_frames = []
        durations = []
        
        for idx, frame in enumerate(ImageSequence.Iterator(im)):
            dur = frame.info.get("duration", 62)
            durations.append(dur)
            
            clean_frame = process_frame(frame)
            processed_frames.append(clean_frame)
            
            # Guardar fotograma PNG transparente individual
            frame_filename = f"frame_{idx:03d}.png"
            clean_frame.save(os.path.join(state_dir, frame_filename), format="PNG", optimize=True)
        
        frame_count = len(processed_frames)
        avg_dur = sum(durations) / max(1, frame_count)
        
        # Guardar GIF transparente optimizado
        out_gif_path = os.path.join(OUT_DIR, item["out_gif"])
        processed_frames[0].save(
            out_gif_path,
            save_all=True,
            append_images=processed_frames[1:],
            loop=0,
            duration=durations,
            disposal=2,  # Clear to transparent before next frame
            transparency=0
        )
        
        metadata["states"][state_name] = {
            "frameCount": frame_count,
            "avgDurationMs": avg_dur,
            "gif": item["out_gif"],
            "framesPath": f"frames/{state_name}/",
            "firstFrame": f"frames/{state_name}/frame_000.png"
        }
        print(f"  ✓ {state_name}: {frame_count} fotogramas transparentes guardados en {state_dir}")
        print(f"  ✓ GIF transparente exportado a {out_gif_path}")

    # Guardar metadatos JSON para Swift/SwiftUI
    meta_path = os.path.join(OUT_DIR, "metadata.json")
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(metadata, f, indent=2, ensure_ascii=False)
    print(f"\n¡Metadatos guardados en {meta_path}!")

if __name__ == "__main__":
    main()
