import time
import sys
from pathlib import Path
import os
import numpy as np
import json

# Add O-RAG paths
PROJECT_PATH = r'd:/orag/orag/android/app/src/main/python'
if PROJECT_PATH not in sys.path:
    sys.path.insert(0, PROJECT_PATH)

import chunker

pdf_path = r'd:/orag/Learning_Python.pdf'

def calibrate_cpu():
    """Measure a CPU-bound task to ground the simulation."""
    size = 2000
    A = np.random.rand(size, size).astype(np.float32)
    B = np.random.rand(size, size).astype(np.float32)
    
    t0 = time.time()
    C = np.dot(A, B)
    t1 = time.time()
    return t1 - t0

def run_real_extraction():
    print(f"Processing actual file: {pdf_path}")
    t0 = time.time()
    small_chunks, parent_chunks = chunker.process_document_hierarchical(pdf_path)
    t1 = time.time()
    
    extraction_time = t1 - t0
    num_chunks = len(small_chunks)
    
    print(f"Extraction successful. Time: {extraction_time:.4f}s")
    
    print("Calibrating CPU...")
    cal_val = calibrate_cpu()
    print(f"Calibration Value: {cal_val:.4f}s")
    
    return {
        "extraction_time": extraction_time,
        "num_chunks": num_chunks,
        "calibration_value": cal_val
    }

if __name__ == "__main__":
    try:
        results = run_real_extraction()
        with open("base_reality.json", "w") as f:
            json.dump(results, f)
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
