{
  description = "taskwarrior-web: minimalistic web UI for Taskwarrior";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Upstream source, tracked as a plain (non-flake) input.
    # Pin to a commit/tag if you want reproducible upgrades:
    #   github:tmahmood/taskwarrior-web/<rev>
    twk-src = {
      url = "github:tmahmood/taskwarrior-web";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, twk-src }:
    (flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };
        lib = pkgs.lib;

        # Upstream says the build fails on stable, so use nightly.
        # The exact nightly is pinned by flake.lock (rust-overlay input).
        rust = pkgs.rust-bin.nightly.latest.minimal;
        rustPlatform = pkgs.makeRustPlatform {
          cargo = rust;
          rustc = rust;
        };

        version = "2.0.1";

        # Step 1: do what build.rs normally does (npm + tailwind + rollup),
        # but with npm deps prefetched so it works inside the sandbox.
        dist = pkgs.stdenv.mkDerivation {
          pname = "taskwarrior-web-dist";
          inherit version;
          src = twk-src;

          npmRoot = "frontend";
          npmDeps = pkgs.fetchNpmDeps {
            name = "taskwarrior-web-npm-deps";
            src = "${twk-src}/frontend";
            # First build will fail and print the real hash; paste it here.
            hash = lib.fakeHash;
          };

          nativeBuildInputs = [ pkgs.nodejs pkgs.npmHooks.npmConfigHook ];

          buildPhase = ''
            runHook preBuild
            mkdir -p dist
            frontend/node_modules/.bin/tailwindcss -i frontend/css/style.css -o dist/style.css
            frontend/node_modules/.bin/rollup -c frontend/rollup.config.js
            cp -r frontend/templates dist
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            cp -r dist $out
            runHook postInstall
          '';
        };

        # Step 2: build the Rust binary. dist/ gets embedded via include_dir,
        # so it must exist at compile time. build.rs is replaced with a no-op.
        taskwarrior-web = rustPlatform.buildRustPackage {
          pname = "taskwarrior-web";
          inherit version;
          src = twk-src;

          cargoLock.lockFile = "${twk-src}/Cargo.lock";

          nativeBuildInputs = [ pkgs.makeWrapper ];

          postPatch = ''
            cp -r ${dist} dist
            chmod -R u+w dist
            echo 'fn main() {}' > build.rs
          '';

          doCheck = false;

          # The app shells out to `task` (and timew for the time-tracking hook).
          postInstall = ''
            wrapProgram $out/bin/taskwarrior-web \
              --prefix PATH : ${lib.makeBinPath [ pkgs.taskwarrior3 pkgs.timewarrior ]}
          '';

          meta = {
            description = "Minimalistic web UI for Taskwarrior";
            homepage = "https://github.com/tmahmood/taskwarrior-web";
            license = lib.licenses.mit;
            mainProgram = "taskwarrior-web";
            platforms = lib.platforms.linux;
          };
        };
      in {
        packages = {
          default = taskwarrior-web;
          inherit taskwarrior-web dist;
        };
        apps.default = flake-utils.lib.mkApp { drv = taskwarrior-web; };
      }))
    // {
      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.services.taskwarrior-web;
          tomlFormat = pkgs.formats.toml { };
          system = pkgs.stdenv.hostPlatform.system;

          taskrc = pkgs.writeText "taskrc" ''
            data.location=${cfg.dataDir}/task
            ${cfg.extraTaskrc}
          '';

          configHome = pkgs.linkFarm "taskwarrior-web-config" [{
            name = "taskwarrior-web/config.toml";
            path = tomlFormat.generate "config.toml" {
              custom_queries = lib.mapAttrs
                (_: q: lib.filterAttrs (_: v: v != null) q)
                cfg.customQueries;
            };
          }];
        in {
          options.services.taskwarrior-web = {
            enable = lib.mkEnableOption "taskwarrior-web";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${system}.default;
              description = "The taskwarrior-web package to run.";
            };

            address = lib.mkOption {
              type = lib.types.str;
              default = "127.0.0.1";
              description = "Address to listen on. Keep on loopback if using a reverse proxy.";
            };

            port = lib.mkOption {
              type = lib.types.port;
              default = 3000;
            };

            openFirewall = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };

            user = lib.mkOption {
              type = lib.types.str;
              default = "taskwarrior-web";
              description = ''
                User to run as. Defaults to a dedicated system user; set this to an
                existing user (and point dataDir at their home) to share data with
                your CLI taskwarrior.
              '';
            };

            group = lib.mkOption {
              type = lib.types.str;
              default = "taskwarrior-web";
            };

            dataDir = lib.mkOption {
              type = lib.types.path;
              default = "/var/lib/taskwarrior-web";
              description = "Holds task/ (taskchampion db) and timewarrior/ data.";
            };

            theme = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum [ "taskwarrior-dark" "taskwarrior-light" ]);
              default = null;
              description = "Force a theme. Null follows the browser preference.";
            };

            font = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "Maple Mono";
            };

            showTimeOfDay = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };

            customQueries = lib.mkOption {
              default = { };
              description = "Custom queries, written to config.toml.";
              example = {
                due_today = {
                  query = "due:today";
                  description = "to be done today";
                  fixed_key = "td";
                };
              };
              type = lib.types.attrsOf (lib.types.submodule {
                options = {
                  query = lib.mkOption { type = lib.types.str; };
                  description = lib.mkOption { type = lib.types.str; };
                  fixed_key = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                  };
                };
              });
            };

            extraTaskrc = lib.mkOption {
              type = lib.types.lines;
              default = "";
              description = "Extra lines appended to the generated .taskrc.";
            };

            environment = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "Extra environment variables for the service.";
            };
          };

          config = lib.mkIf cfg.enable {
            users.users = lib.mkIf (cfg.user == "taskwarrior-web") {
              taskwarrior-web = {
                isSystemUser = true;
                group = cfg.group;
                home = cfg.dataDir;
                createHome = true;
              };
            };
            users.groups = lib.mkIf (cfg.group == "taskwarrior-web") {
              taskwarrior-web = { };
            };

            systemd.tmpfiles.rules = [
              "d ${cfg.dataDir}/task 0750 ${cfg.user} ${cfg.group} -"
              "d ${cfg.dataDir}/timewarrior 0750 ${cfg.user} ${cfg.group} -"
            ];

            networking.firewall.allowedTCPPorts =
              lib.mkIf cfg.openFirewall [ cfg.port ];

            systemd.services.taskwarrior-web = {
              description = "taskwarrior-web";
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];

              environment = {
                HOME = cfg.dataDir;
                TASKRC = "${taskrc}";
                TASKDATA = "${cfg.dataDir}/task";
                TIMEWARRIORDB = "${cfg.dataDir}/timewarrior";
                TWK_SERVER_ADDR = cfg.address;
                TWK_SERVER_PORT = toString cfg.port;
              }
              // lib.optionalAttrs (cfg.theme != null) { TWK_THEME = cfg.theme; }
              // lib.optionalAttrs (cfg.font != null) { TWK_USE_FONT = cfg.font; }
              // lib.optionalAttrs cfg.showTimeOfDay { DISPLAY_TIME_OF_THE_DAY = "1"; }
              // lib.optionalAttrs (cfg.customQueries != { }) { XDG_CONFIG_HOME = "${configHome}"; }
              // cfg.environment;

              serviceConfig = {
                ExecStart = lib.getExe cfg.package;
                User = cfg.user;
                Group = cfg.group;
                WorkingDirectory = cfg.dataDir;
                Restart = "on-failure";
                RestartSec = 3;

                # Hardening
                NoNewPrivileges = true;
                PrivateTmp = true;
                ProtectSystem = "strict";
                ProtectHome = lib.mkDefault true;
                ReadWritePaths = [ cfg.dataDir ];
                ProtectKernelTunables = true;
                ProtectControlGroups = true;
                RestrictSUIDSGID = true;
              };
            };
          };
        };
    };
}
