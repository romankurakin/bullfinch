use clap::{Args, Parser, Subcommand, ValueEnum};
use std::env;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const BOOT_OK: &str = "[BOOT:OK]";
const SMOKE_TIMEOUT: Duration = Duration::from_secs(15);
const PEEK_TIMEOUT: Duration = Duration::from_secs(4);

#[derive(Parser)]
#[command(name = "bullfinch-tools")]
#[command(about = "Build and test Bullfinch developer targets.")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    Build(BuildArgs),
    Qemu(BuildArgs),
    Smoke(SmokeArgs),
    Peek(PeekArgs),
    Disasm(BuildArgs),
    Clean,
}

#[derive(Args)]
struct BuildArgs {
    arch: Arch,
    #[arg(default_value = "debug")]
    mode: Mode,
}

#[derive(Args)]
struct SmokeArgs {
    #[arg(long)]
    peek: bool,
    #[arg(long)]
    verbose: bool,
    arch: Option<Arch>,
    mode: Option<Mode>,
}

#[derive(Args)]
struct PeekArgs {
    #[arg(long)]
    verbose: bool,
    arch: Option<Arch>,
    mode: Option<Mode>,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("tools: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let cli = Cli::parse();
    match cli.command {
        Commands::Build(args) => build_kernel(args.arch, args.mode).map(|_| ()),
        Commands::Qemu(args) => qemu_command(args),
        Commands::Smoke(args) => smoke_command(args),
        Commands::Peek(args) => smoke_command(SmokeArgs {
            peek: true,
            verbose: args.verbose,
            arch: args.arch,
            mode: args.mode,
        }),
        Commands::Disasm(args) => disasm_command(args),
        Commands::Clean => clean_command(),
    }
}

fn qemu_command(args: BuildArgs) -> Result<(), String> {
    let artifact = build_kernel(args.arch, args.mode)?;
    let board = board_for(args.arch);
    let mut command = qemu_command_for(board, &artifact);
    let status = command.status().map_err(|error| {
        format!(
            "failed to start {}: {error}",
            command.get_program().to_string_lossy()
        )
    })?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("qemu exited with {status}"))
    }
}

fn smoke_command(args: SmokeArgs) -> Result<(), String> {
    let variants = smoke_variants(args.arch, args.mode, args.peek)?;
    let mut failed = 0usize;
    for (arch, mode) in variants {
        if !run_smoke_variant(arch, mode, args.peek, args.verbose)? {
            failed += 1;
        }
    }

    if failed == 0 {
        Ok(())
    } else {
        Err(format!("{failed} smoke variant(s) failed"))
    }
}

fn disasm_command(args: BuildArgs) -> Result<(), String> {
    let artifact = build_kernel(args.arch, args.mode)?;
    let mut command = Command::new(env::var_os("OBJDUMP").unwrap_or_else(|| "llvm-objdump".into()));
    command.arg("-d");
    if args.arch == Arch::Riscv64 {
        command.args(["-M", "no-aliases"]);
    } else {
        command.arg("--mattr=+all");
    }
    command.arg(artifact.elf);
    run_status(command, "llvm-objdump")
}

fn clean_command() -> Result<(), String> {
    let root = repo_root();
    remove_dir_if_exists(root.join("target"))?;
    Ok(())
}

fn build_kernel(arch: Arch, mode: Mode) -> Result<KernelArtifact, String> {
    let mut command = cargo_command();
    command.args([
        "build",
        "-p",
        "bullfinch-kernel",
        "--quiet",
        "--bin",
        "kernel",
        "--target",
        arch.rust_target(),
    ]);
    if mode == Mode::Release {
        command.arg("--release");
    }
    run_status(command, &format!("build {} {}", arch.name(), mode.name()))?;

    let root = repo_root();
    let profile = mode.profile();
    let source = root
        .join("target")
        .join(arch.rust_target())
        .join(profile)
        .join("kernel");
    let out_dir = root.join("target/bullfinch/kernel");
    fs::create_dir_all(&out_dir)
        .map_err(|error| format!("failed to create {}: {error}", out_dir.display()))?;

    let base = format!("{}-qemu_virt-{}", arch.name(), mode.name());
    let elf = out_dir.join(format!("{base}.elf"));
    let bin = out_dir.join(format!("{base}.bin"));
    fs::copy(&source, &elf).map_err(|error| {
        format!(
            "failed to copy {} to {}: {error}",
            source.display(),
            elf.display()
        )
    })?;

    let mut objcopy = Command::new(env::var_os("OBJCOPY").unwrap_or_else(|| "llvm-objcopy".into()));
    objcopy.args(["-O", "binary"]);
    objcopy.arg(&source);
    objcopy.arg(&bin);
    run_status(objcopy, "llvm-objcopy")?;

    Ok(KernelArtifact { elf, bin })
}

fn run_smoke_variant(arch: Arch, mode: Mode, peek: bool, verbose: bool) -> Result<bool, String> {
    let artifact = build_kernel(arch, mode)?;
    let board = board_for(arch);
    let name = format!("{}-qemu_virt-{}", arch.name(), mode.name());
    let mut command = qemu_command_for(board, &artifact);
    if verbose {
        eprintln!("{name}: running {:?}", command);
    }

    let output = run_with_timeout(
        &mut command,
        if peek { PEEK_TIMEOUT } else { SMOKE_TIMEOUT },
    )?;
    let filtered = normalize_output(filter_output(&output));

    let root = repo_root();
    let log_dir = root.join("target/bullfinch/tests");
    fs::create_dir_all(&log_dir)
        .map_err(|error| format!("failed to create {}: {error}", log_dir.display()))?;
    fs::write(log_dir.join(format!("{name}.log")), filtered.as_bytes())
        .map_err(|error| format!("failed to write smoke log: {error}"))?;

    if peek {
        print_block(&name, "peek", &filtered);
        return Ok(true);
    }

    if filtered.contains(BOOT_OK) {
        println!("{name}: PASS");
        Ok(true)
    } else {
        print_block(&name, "timeout", &filtered);
        Ok(false)
    }
}

fn smoke_variants(
    arch: Option<Arch>,
    mode: Option<Mode>,
    peek: bool,
) -> Result<Vec<(Arch, Mode)>, String> {
    match (arch, mode, peek) {
        (None, None, _) => Ok(vec![
            (Arch::Arm64, Mode::Debug),
            (Arch::Arm64, Mode::Release),
            (Arch::Riscv64, Mode::Debug),
            (Arch::Riscv64, Mode::Release),
        ]),
        (Some(arch), None, _) => Ok(vec![(arch, Mode::Debug), (arch, Mode::Release)]),
        (Some(arch), Some(mode), _) => Ok(vec![(arch, mode)]),
        (None, Some(_), _) => Err("mode requires an architecture".to_string()),
    }
}

fn qemu_command_for(board: Board, artifact: &KernelArtifact) -> Command {
    let mut command = Command::new(board.system);
    command.args(["-machine", board.machine]);
    if let Some(cpu) = board.cpu {
        command.args(["-cpu", cpu]);
    }
    command.args(board.args);
    command.arg("-nographic");
    command.arg("-kernel");
    command.arg(match board.boot_image {
        BootImage::Elf => &artifact.elf,
        BootImage::Bin => &artifact.bin,
    });
    command
}

fn run_with_timeout(command: &mut Command, timeout: Duration) -> Result<String, String> {
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = command.spawn().map_err(|error| {
        format!(
            "failed to start {}: {error}",
            command.get_program().to_string_lossy()
        )
    })?;

    let stdout = take_reader(&mut child, Stream::Stdout)?;
    let stderr = take_reader(&mut child, Stream::Stderr)?;
    let start = Instant::now();

    loop {
        if let Some(_status) = child
            .try_wait()
            .map_err(|error| format!("failed to poll child: {error}"))?
        {
            break;
        }
        if start.elapsed() >= timeout {
            let _ = child.kill();
            let _ = child.wait();
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }

    let mut output = stdout
        .join()
        .map_err(|_| "stdout reader thread panicked".to_string())??;
    let stderr = stderr
        .join()
        .map_err(|_| "stderr reader thread panicked".to_string())??;
    output.push_str(&stderr);
    Ok(output)
}

fn take_reader(
    child: &mut Child,
    stream: Stream,
) -> Result<thread::JoinHandle<Result<String, String>>, String> {
    let reader: Box<dyn Read + Send> = match stream {
        Stream::Stdout => Box::new(
            child
                .stdout
                .take()
                .ok_or_else(|| "child stdout was not piped".to_string())?,
        ),
        Stream::Stderr => Box::new(
            child
                .stderr
                .take()
                .ok_or_else(|| "child stderr was not piped".to_string())?,
        ),
    };

    Ok(thread::spawn(move || read_to_string(reader)))
}

fn read_to_string(mut reader: Box<dyn Read + Send>) -> Result<String, String> {
    let mut bytes = Vec::new();
    reader
        .read_to_end(&mut bytes)
        .map_err(|error| format!("failed to read child output: {error}"))?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn filter_output(output: &str) -> &str {
    if let Some(index) = output
        .find("[BOOT:STARTED]")
        .or_else(|| output.find("[01/10]"))
        .or_else(|| output.find(BOOT_OK))
    {
        let start = output[..index].rfind('\n').map_or(index, |line| line + 1);
        return &output[start..];
    }
    output
}

fn normalize_output(output: &str) -> String {
    output.replace('\r', "")
}

fn print_block(name: &str, status: &str, output: &str) {
    println!("\n---- {name}: {status} ----");
    print!("{output}");
    if !output.ends_with('\n') {
        println!();
    }
    println!("---- end ----");
}

fn cargo_command() -> Command {
    let mut command = Command::new("cargo");
    command.current_dir(repo_root());
    command
}

fn run_status(mut command: Command, label: &str) -> Result<(), String> {
    let status = command.status().map_err(|error| {
        format!(
            "failed to start {} for {label}: {error}",
            command.get_program().to_string_lossy()
        )
    })?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{label} exited with {status}"))
    }
}

fn remove_dir_if_exists(path: PathBuf) -> Result<(), String> {
    if !path.exists() {
        return Ok(());
    }
    fs::remove_dir_all(&path)
        .map_err(|error| format!("failed to remove {}: {error}", path.display()))
}

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .expect("tools/xtask has a workspace grandparent")
        .to_path_buf()
}

fn board_for(arch: Arch) -> Board {
    match arch {
        Arch::Arm64 => Board {
            system: "qemu-system-aarch64",
            machine: "virt,gic-version=3",
            cpu: Some("cortex-a76"),
            args: &["-smp", "2", "-m", "2G"],
            boot_image: BootImage::Bin,
        },
        Arch::Riscv64 => Board {
            system: "qemu-system-riscv64",
            machine: "virt",
            cpu: Some("rv64"),
            args: &["-smp", "2", "-m", "2G", "-bios", "default"],
            boot_image: BootImage::Elf,
        },
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
enum Arch {
    #[value(alias = "aarch64")]
    Arm64,
    #[value(alias = "riscv")]
    Riscv64,
}

impl Arch {
    fn name(self) -> &'static str {
        match self {
            Self::Arm64 => "arm64",
            Self::Riscv64 => "riscv64",
        }
    }

    fn rust_target(self) -> &'static str {
        match self {
            Self::Arm64 => "aarch64-unknown-none-softfloat",
            Self::Riscv64 => "riscv64gc-unknown-none-elf",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
enum Mode {
    Debug,
    #[value(alias = "ReleaseFast")]
    Release,
}

impl Mode {
    fn name(self) -> &'static str {
        match self {
            Self::Debug => "debug",
            Self::Release => "release",
        }
    }

    fn profile(self) -> &'static str {
        match self {
            Self::Debug => "debug",
            Self::Release => "release",
        }
    }
}

#[derive(Clone, Copy)]
struct Board {
    system: &'static str,
    machine: &'static str,
    cpu: Option<&'static str>,
    args: &'static [&'static str],
    boot_image: BootImage,
}

#[derive(Clone, Copy)]
enum BootImage {
    Elf,
    Bin,
}

struct KernelArtifact {
    elf: PathBuf,
    bin: PathBuf,
}

enum Stream {
    Stdout,
    Stderr,
}
