class Cleaner < Formula
  desc "Safe, native macOS disk cleaner for developers"
  homepage "https://github.com/hung977/cleaner-cli"
  url "https://github.com/hung977/cleaner-cli/archive/refs/tags/v0.6.0.tar.gz"
  sha256 "75cb138789e1cb19f32914a602553625c34267c5a89d8b62b1380aaba44d3bbe"
  license "MIT"
  head "https://github.com/hung977/cleaner-cli.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "--configuration", "release", "--disable-sandbox"
    bin.install ".build/release/cleaner"
  end

  test do
    assert_match "0.6.0", shell_output("#{bin}/cleaner --version")
    assert_match "DISK RECLAIMABLE", shell_output("CLEANER_TEST_HOME=#{testpath} #{bin}/cleaner --dry-run --no-color")
  end
end
