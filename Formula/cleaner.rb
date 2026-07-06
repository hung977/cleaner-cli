class Cleaner < Formula
  desc "Safe, native macOS disk cleaner for developers"
  homepage "https://github.com/hung977/cleaner-cli"
  url "https://github.com/hung977/cleaner-cli/archive/refs/tags/v0.5.0.tar.gz"
  sha256 "7f876a707da12a4f22f9b3ec9b3307b5356cc3d5d71be3eba7dfeb5339a5f121"
  license "MIT"
  head "https://github.com/hung977/cleaner-cli.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "--configuration", "release", "--disable-sandbox"
    bin.install ".build/release/cleaner"
  end

  test do
    assert_match "0.5.0", shell_output("#{bin}/cleaner --version")
    assert_match "DISK RECLAIMABLE", shell_output("CLEANER_TEST_HOME=#{testpath} #{bin}/cleaner --dry-run --no-color")
  end
end
