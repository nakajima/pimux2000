use std::{
    env, fs,
    io::Write,
    path::{Path, PathBuf},
};

use flate2::{Compression, write::GzEncoder};

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));

    for asset in ["reset.css", "pimux.css"] {
        let source = manifest_dir.join("static").join(asset);
        println!("cargo:rerun-if-changed={}", source.display());
    }

    if env::var("PROFILE").ok().as_deref() != Some("release") {
        return;
    }

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    for asset in ["reset.css", "pimux.css"] {
        let source = manifest_dir.join("static").join(asset);
        write_gzipped_asset(&source, &out_dir.join(format!("{asset}.gz")));
    }
}

fn write_gzipped_asset(source: &Path, destination: &Path) {
    let input = fs::read(source)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", source.display()));

    let file = fs::File::create(destination)
        .unwrap_or_else(|error| panic!("failed to create {}: {error}", destination.display()));
    let mut encoder = GzEncoder::new(file, Compression::best());
    encoder
        .write_all(&input)
        .unwrap_or_else(|error| panic!("failed to gzip {}: {error}", source.display()));
    encoder
        .finish()
        .unwrap_or_else(|error| panic!("failed to finish {}: {error}", destination.display()));
}
