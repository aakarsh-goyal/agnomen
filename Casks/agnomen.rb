cask "agnomen" do
  version "1.0.0"
  sha256 "0207946a7c51a616591499a17387c3dfe5cc948920ebb7077b3ca5fa0278ca1a"

  url "https://github.com/aakarsh-goyal/agnomen/releases/download/v#{version}/Agnomen-#{version}-arm64.zip"
  name "Agnomen"
  desc "Rename files after what is inside them, using Apple's on-device model"
  homepage "https://github.com/aakarsh-goyal/agnomen"

  depends_on arch: :arm64
  depends_on macos: :golden_gate # macOS 27+

  app "Agnomen.app"

  # Ad-hoc signed, not notarized: clear the download quarantine flag so it launches.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "/Applications/Agnomen.app"],
                          must_succeed: false
  end

  zap trash: [
    "~/Library/Application Scripts/com.agnomen.app",
    "~/Library/Containers/com.agnomen.app",
    "~/Library/Preferences/com.agnomen.app.plist",
  ]
end
