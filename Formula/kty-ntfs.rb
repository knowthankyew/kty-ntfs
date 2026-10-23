class KtyNtfs < Formula
  desc "Native, forensically clean NTFS read/write storage engine for macOS"
  homepage "https://knowthankyew.com"
  url "https://github.com/knowthankyew/kty-ntfs/archive/refs/tags/v0.1.0.tar.gz"
  license "GPL-2.0-or-later"
  head "https://github.com/knowthankyew/kty-ntfs.git", branch: "main"

  depends_on :macos => :sonoma

  def install
    system "make", "all"
    bin.install "build/bin/kty-ntfs"
    bin.install "build/bin/kty-ntfsd"
    (prefix/"Filesystems").install "build/bin/kty-ntfs-fs.appex"
  end

  def caveats
    <<~EOS
      kty-ntfs requires root permissions to manage system block devices and DiskArbitration mounts.

      To run the daemon directly:
        sudo #{opt_bin}/kty-ntfsd

      To install the system-wide launchd daemon service:
        sudo make install
    EOS
  end

  service do
    run [opt_bin/"kty-ntfsd"]
    keep_alive true
    require_root true
    log_path var/"log/kty-ntfsd.log"
    error_log_path var/"log/kty-ntfsd.err"
  end

  test do
    assert_match "kty-ntfs", shell_output("#{bin}/kty-ntfs help")
    assert_match "Usage:", shell_output("#{bin}/kty-ntfs help")
  end
end
