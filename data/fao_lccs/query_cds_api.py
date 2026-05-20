# Fetch data using Copernicus CDS API: 

import os
import fire
import cdsapi
import zipfile
import tempfile
from pathlib import Path
from sys import exit

Path("data/urban_fraction/raw").mkdir(exist_ok=True)

DATASET_LAST_UPDATED_YEAR = 2022 

def unzip(zip_path, folder):
    zip_path = Path(zip_path)
    folder = Path(folder)

    folder.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(zip_path, 'r') as z:
        z.extractall(folder)
        file_list = [folder / name for name in z.namelist()]
    return file_list

def download(start_year: int, end_year: int | None = None):
    end_year = end_year or DATASET_LAST_UPDATED_YEAR
    if start_year > end_year:
        print(f"satellite_land_cover: error {start_year=} is after {end_year=}")
        exit(1)
    years = [str(y) for y in range(start_year, end_year + 1)]
    print(f"satellite_land_cover: downloading years {start_year}-{end_year}")

    dataset = "satellite-land-cover"
    request = {
        "variable": "all",
        "year": years,
        "version": ["v2_1_1"]
    }
    client = cdsapi.Client()
    with tempfile.NamedTemporaryFile(prefix="satellite_land_cover_", suffix='.zip') as f:
        client.retrieve(dataset, request).download(f.name)
        files = unzip(f.name, data / "raw")
    print("\n".join(map(str, files)))

if __name__ == "__main__":
    fire.Fire(download)
