let
  nixpkgs = fetchTarball "https://github.com/NixOS/nixpkgs/archive/1bebb6ee89a51ac1357798d4a72e745279f10484.tar.gz";
  pkgs = import nixpkgs { };
in
pkgs.mkShell {
  buildInputs = with pkgs; [
    zig
    zls
    tailwindcss_4
    postgresql
  ];
}
