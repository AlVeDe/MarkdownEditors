//! `cargo run --example render_pdf -- in.md out.pdf` — renders a Markdown
//! file to PDF without the app (formulas and diagrams print as source).
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let input = std::fs::read_to_string(&args[1]).expect("read input");
    let pdf = mdcore::render::pdf::export(&input, &[], &[], &[]);
    std::fs::write(&args[2], pdf).expect("write output");
}
