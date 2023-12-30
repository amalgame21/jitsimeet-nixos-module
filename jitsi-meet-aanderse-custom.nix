{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.jitsi-meet;

  # The configuration files are JS of format "var <<string>> = <<JSON>>;". In order to
  # override only some settings, we need to extract the JSON, use jq to merge it with
  # the config provided by user, and then reconstruct the file.
  overrideJs =
    source: varName: userCfg: appendExtra:
    let
      extractor = pkgs.writeText "extractor.js" ''
        var fs = require("fs");
        eval(fs.readFileSync(process.argv[2], 'utf8'));
        process.stdout.write(JSON.stringify(eval(process.argv[3])));
      '';
      userJson = pkgs.writeText "user.json" (builtins.toJSON userCfg);
    in (pkgs.runCommand "${varName}.js" { } ''
      ${pkgs.nodejs}/bin/node ${extractor} ${source} ${varName} > default.json
      (
        echo "var ${varName} = "
        ${pkgs.jq}/bin/jq -s '.[0] * .[1]' default.json ${userJson}
        echo ";"
        echo ${escapeShellArg appendExtra}
      ) > $out
    '');

  # Essential config - it's probably not good to have these as option default because
  # types.attrs doesn't do merging. Let's merge explicitly, can still be overridden if
  # user desires.
  defaultCfg = {
    hosts = {
      domain = cfg.hostName;
      muc = "conference.${cfg.hostName}";
      focus = "focus.${cfg.hostName}";
    };
    bosh = "//${cfg.hostName}/http-bind";
    websocket = "wss://${cfg.hostName}/xmpp-websocket";

    fileRecordingsEnabled = true;
    liveStreamingEnabled = true;
    hiddenDomain = "recorder.${cfg.hostName}";
  };
in
{
  options.services.jitsi-meet = with types; {
    enable = mkEnableOption (lib.mdDoc "Jitsi Meet - Secure, Simple and Scalable Video Conferences");

    hostName = mkOption {
      type = str;
      example = "meet.example.org";
      description = lib.mdDoc ''
        FQDN of the Jitsi Meet instance.
      '';
    };

    config = mkOption {
      type = attrs;
      default = { };
      example = literalExpression ''
        {
          enableWelcomePage = false;
          defaultLang = "fi";
        }
      '';
      description = lib.mdDoc ''
        Client-side web application settings that override the defaults in {file}`config.js`.

        See <https://github.com/jitsi/jitsi-meet/blob/master/config.js> for default
        configuration with comments.
      '';
    };

    extraConfig = mkOption {
      type = lines;
      default = "";
      description = lib.mdDoc ''
        Text to append to {file}`config.js` web application config file.

        Can be used to insert JavaScript logic to determine user's region in cascading bridges setup.
      '';
    };

    interfaceConfig = mkOption {
      type = attrs;
      default = { };
      example = literalExpression ''
        {
          SHOW_JITSI_WATERMARK = false;
          SHOW_WATERMARK_FOR_GUESTS = false;
        }
      '';
      description = lib.mdDoc ''
        Client-side web-app interface settings that override the defaults in {file}`interface_config.js`.

        See <https://github.com/jitsi/jitsi-meet/blob/master/interface_config.js> for
        default configuration with comments.
      '';
    };

    videobridge = {
      enable = mkOption {
        type = bool;
        default = true;
        description = lib.mdDoc ''
          Whether to enable Jitsi Videobridge instance and configure it to connect to Prosody.

          Additional configuration is possible with {option}`services.jitsi-videobridge`.
        '';
      };

      passwordFile = mkOption {
        type = nullOr str;
        default = null;
        example = "/run/keys/videobridge";
        description = lib.mdDoc ''
          File containing password to the Prosody account for videobridge.

          If `null`, a file with password will be generated automatically. Setting
          this option is useful if you plan to connect additional videobridges to the XMPP server.
        '';
      };
    };

    jicofo.enable = mkOption {
      type = bool;
      default = true;
      description = lib.mdDoc ''
        Whether to enable JiCoFo instance and configure it to connect to Prosody.

        Additional configuration is possible with {option}`services.jicofo`.
      '';
    };

    jibri.enable = mkOption {
      type = bool;
      default = false;
      description = lib.mdDoc ''
        Whether to enable a Jibri instance and configure it to connect to Prosody.

        Additional configuration is possible with {option}`services.jibri`, and
        {option}`services.jibri.finalizeScript` is especially useful.
      '';
    };

    nginx.enable = mkOption {
      type = bool;
      default = true;
      description = lib.mdDoc ''
        Whether to enable nginx virtual host that will serve the javascript application and act as
        a proxy for the XMPP server. Further nginx configuration can be done by adapting
        {option}`services.nginx.virtualHosts.<hostName>`.
        When this is enabled, ACME will be used to retrieve a TLS certificate by default. To disable
        this, set the {option}`services.nginx.virtualHosts.<hostName>.enableACME` to
        `false` and if appropriate do the same for
        {option}`services.nginx.virtualHosts.<hostName>.forceSSL`.
      '';
    };

    caddy.enable = mkEnableOption (lib.mdDoc "Whether to enable caddy reverse proxy to expose jitsi-meet");

    prosody.enable = mkOption {
      type = bool;
      default = true;
      description = lib.mdDoc ''
        Whether to configure Prosody to relay XMPP messages between Jitsi Meet components. Turn this
        off if you want to configure it manually.
      '';
    };

    excalidraw.enable = mkEnableOption (lib.mdDoc "Excalidraw collaboration backend for Jitsi");
    excalidraw.port = mkOption {
      type = types.port;
      default = 3002;
      description = lib.mdDoc ''The port which the Excalidraw backend for Jitsi should listen to.'';
    };

    secureDomain.enable = mkEnableOption (lib.mdDoc "Authenticated room creation");
  };

  config = mkIf cfg.enable {
    services.prosody = mkIf cfg.prosody.enable {
      enable = mkDefault true;
      xmppComplianceSuite = mkDefault false;

      # With reference to jitsi-meet debian example
      # https://github.com/jitsi/jitsi-meet/blob/master/doc/debian/jitsi-meet-prosody/prosody.cfg.lua-jvb.example

      # With reference to original jitsi-meet.nix
      # https://github.com/NixOS/nixpkgs/blob/nixos-23.11/nixos/modules/services/web-apps/jitsi-meet.nix

      settings = {
        modules_enabled = [
        # From original jitsi-meet.nix
        "bosh"
        # "pubsub" This makes the "Invite to Conversations" (mod_invites) menu not showing up in the Android Conversations app. Must not enable globally
        "ping"
        "roster"
        "saslauth"
        "smacks"
        "tls"
        "websocket"
        ];

        # From original jitsi-meet.nix
        modules_disabled = [ "admin_adhoc" ];
        plugin_paths = [ "${pkgs.jitsi-meet-prosody}/share/prosody-plugins" ];

        muc_mapper_domain_base = "${cfg.hostName}";

        cross_domain_websocket = true; # prosodyctl said this is depricated
        consider_websocket_secure = true;

        unlimited_jids = [
          "focus@auth.${cfg.hostName}"
          "jvb@auth.${cfg.hostName}"
        ];

        # From debian example
        cross_domain_bosh = false; # prosodyctl said this is depricated
        consider_bosh_secure = true;
      };
      components."conference.${cfg.hostName}" = {
        module = "muc";
        settings = {
          name = "Jitsi Meet MUC";
          muc_room_locking = false;
          muc_room_default_public_jids = true;

          # From debian example
          restrict_room_creation = true;
          storage = "memory";
          admins = [ "focus@auth.${cfg.hostName}" ];
          modules_enabled = [
            "muc_hide_all"
            "muc_meeting_id"
            "muc_domain_mapper"
            "polls"
            # "token_verification"
            "muc_rate_limit"
            "muc_password_whitelist"
          ];
          muc_password_whitelist = [
            "focus@auth.${cfg.hostName}"
          ];
        };
      };
      components."breakout.${cfg.hostName}" = {
        module = "muc";
        settings = {
          # From original jitsi-meet.nix
          name = "Jitsi Meet Breakout MUC";
          muc_room_locking = false;
          muc_room_default_public_jids = true;
          restrict_room_creation = true;
          storage = "memory";
          admins = [ "focus@auth.${cfg.hostName}" ];

          # From debian example
          modules_enabled = [
            "muc_hide_all"
            "muc_meeting_id"
            "muc_domain_mapper"
            "muc_rate_limit"
            "polls"
          ];
        };
      };
      components."internal.auth.${cfg.hostName}" = {
        module = "muc";
        settings = {
          # From original jitsi-meet.nix
          name = "Jitsi Meet Videobridge MUC";
          muc_room_locking = false;
          muc_room_default_public_jids = true;
          storage = "memory";
          admins = [ "focus@auth.${cfg.hostName}" "jvb@auth.${cfg.hostName}" ];
          # muc_room_cache_size = 1000;

          # From debian example
          modules_enabled = [
            "muc_hide_all"
            "ping"
          ];
        };
      };

      components."focus.${cfg.hostName}" = {
        module = "client_proxy";
        settings = {
          target_address = "focus@auth.${cfg.hostName}";
        };
      };
      components."speakerstats.${cfg.hostName}" = {
        module = "speakerstats_component";
        settings = {
          muc_component = "conference.${cfg.hostName}";
        };
      };
      components."conferenceduration.${cfg.hostName}" = {
        module = "conference_duration_component";
        settings = {
          muc_component = "conference.${cfg.hostName}";
        };
      };
      components."endconference.${cfg.hostName}" = {
        module = "end_conference";
        settings = {
          muc_component = "conference.${cfg.hostName}";
        };
      };
      components."avmoderation.${cfg.hostName}" = {
        module = "av_moderation_component";
        settings = {
          muc_component = "conference.${cfg.hostName}";
        };
      };
      components."metadata.${cfg.hostName}" = {
        module = "room_metadata_component";
        settings = {
          muc_component = "conference.${cfg.hostName}";
          breakout_rooms_component = "breakout.${cfg.hostName}";
        };
      };
      components."lobby.${cfg.hostName}" = {
        module = "muc";
        settings = {
          # From original jitsi-meet.nix
          name = "Jitsi Meet Lobby MUC";
          muc_room_locking = false;
          muc_room_default_public_jids = true;
          restrict_room_creation = true;
          storage = "memory";

          # From debian example
          modules_enabled = [
            "muc_hide_all"
            "muc_rate_limit"
            "polls"
          ];
        };
      };
      virtualHosts.${cfg.hostName} = {
        settings = {
          authentication = if cfg.secureDomain.enable then "internal_hashed" else "jitsi-anonymous";

          c2s_require_encryption = false;
          # c2s_require_encryption = true; # for testing

          admins = [ "focus@auth.${cfg.hostName}" ];
          # From original jitsi-meet.nix
          smacks_max_unacked_stanzas = 5;
          smacks_hibernation_time = 60;
          smacks_max_hibernated_sessions = 1;
          smacks_max_old_sessions = 1;

          av_moderation_component = "avmoderation.${cfg.hostName}";
          speakerstats_component = "speakerstats.${cfg.hostName}";
          conference_duration_component = "conferenceduration.${cfg.hostName}";
          end_conference_component = "endconference.${cfg.hostName}";

          # From debian example
          # we need bosh
          modules_enabled = [
            "bosh"
            "pubsub"
            "ping" # -- Enable mod_ping
            "speakerstats"
            "external_services"
            "conference_duration"
            "end_conference"
            "muc_lobby_rooms"
            "muc_breakout_rooms"
            "av_moderation"
            "room_metadata"
          ];
          lobby_muc = "lobby.${cfg.hostName}";
          breakout_rooms_muc = "breakout.${cfg.hostName}";
          room_metadata_component = "metadata.${cfg.hostName}";
          main_muc = "conference.${cfg.hostName}";
          # muc_lobby_whitelist = [ "recorder.${cfg.hostName}" ]; # Here we can whitelist jibri to enter lobby enabled rooms

          ssl = {
            certificate = "/var/lib/jitsi-meet/jitsi-meet.crt";
            key = "/var/lib/jitsi-meet/jitsi-meet.key";
          };
        };
      };
      virtualHosts."auth.${cfg.hostName}" = {
        settings = {
          authentication = "internal_hashed";
          # From debian example
          modules_enabled = [
            "limits_exception"
          ];
          ssl = {
            certificate = "/var/lib/jitsi-meet/jitsi-meet.crt";
            key = "/var/lib/jitsi-meet/jitsi-meet.key";
          };
        };
      };
      virtualHosts."recorder.${cfg.hostName}" = {
        settings = {
          # authentication = "internal_plain"; # From original jitsi-meet.nix
          authentication = "internal_hashed"; # For testing
          c2s_require_encryption = false;
          # c2s_require_encryption = true; # For testing
        };
      };
      virtualHosts."guest.${cfg.hostName}" = {
        settings = {
          authentication = "anonymous";
          c2s_require_encryption = false;
          # c2s_require_encryption = true; # For testing
        };
      };
    };
    systemd.services.prosody = mkIf cfg.prosody.enable {
      preStart = let
        videobridgeSecret = if cfg.videobridge.passwordFile != null then cfg.videobridge.passwordFile else "/var/lib/jitsi-meet/videobridge-secret";
      in ''
        ${config.services.prosody.package}/bin/prosodyctl register focus auth.${cfg.hostName} "$(cat /var/lib/jitsi-meet/jicofo-user-secret)"
        ${config.services.prosody.package}/bin/prosodyctl register jvb auth.${cfg.hostName} "$(cat ${videobridgeSecret})"
        ${config.services.prosody.package}/bin/prosodyctl mod_roster_command subscribe focus.${cfg.hostName} focus@auth.${cfg.hostName}
        ${config.services.prosody.package}/bin/prosodyctl register jibri auth.${cfg.hostName} "$(cat /var/lib/jitsi-meet/jibri-auth-secret)"
        ${config.services.prosody.package}/bin/prosodyctl register recorder recorder.${cfg.hostName} "$(cat /var/lib/jitsi-meet/jibri-recorder-secret)"
      '';
      serviceConfig = {
        EnvironmentFile = [ "/var/lib/jitsi-meet/secrets-env" ];
        SupplementaryGroups = [ "jitsi-meet" ];
      };
      reloadIfChanged = true;
    };

    users.groups.jitsi-meet = { };
    systemd.tmpfiles.rules = [
      "d '/var/lib/jitsi-meet' 0750 root jitsi-meet - -"
    ];

    systemd.services.jitsi-meet-init-secrets = {
      wantedBy = [ "multi-user.target" ];
      before = [ "jicofo.service" "jitsi-videobridge2.service" ] ++ (optional cfg.prosody.enable "prosody.service");
      serviceConfig = {
        Type = "oneshot";
      };

      script = let
        secrets = [ "jicofo-component-secret" "jicofo-user-secret" "jibri-auth-secret" "jibri-recorder-secret" ] ++ (optional (cfg.videobridge.passwordFile == null) "videobridge-secret");
      in
      ''
        cd /var/lib/jitsi-meet
        ${concatMapStringsSep "\n" (s: ''
          if [ ! -f ${s} ]; then
            tr -dc a-zA-Z0-9 </dev/urandom | head -c 64 > ${s}
            chown root:jitsi-meet ${s}
            chmod 640 ${s}
          fi
        '') secrets}

        # for easy access in prosody
        echo "JICOFO_COMPONENT_SECRET=$(cat jicofo-component-secret)" > secrets-env
        chown root:jitsi-meet secrets-env
        chmod 640 secrets-env
      ''
      + optionalString cfg.prosody.enable ''
        # generate self-signed certificates
        if [ ! -f /var/lib/jitsi-meet.crt ]; then
          ${getBin pkgs.openssl}/bin/openssl req \
            -x509 \
            -newkey rsa:4096 \
            -keyout /var/lib/jitsi-meet/jitsi-meet.key \
            -out /var/lib/jitsi-meet/jitsi-meet.crt \
            -days 36500 \
            -nodes \
            -subj '/CN=${cfg.hostName}/CN=auth.${cfg.hostName}'
          chmod 640 /var/lib/jitsi-meet/jitsi-meet.{crt,key}
          chown root:jitsi-meet /var/lib/jitsi-meet/jitsi-meet.{crt,key}
        fi
      '';
    };

    systemd.services.jitsi-excalidraw = mkIf cfg.excalidraw.enable {
      description = "Excalidraw collaboration backend for Jitsi";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      environment.PORT = toString cfg.excalidraw.port;

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.jitsi-excalidraw}/bin/jitsi-excalidraw-backend";
        Restart = "on-failure";
        Group = "jitsi-meet";
      };
    };

    services.nginx = mkIf cfg.nginx.enable {
      enable = mkDefault true;
      virtualHosts.${cfg.hostName} = {
        enableACME = mkDefault true;
        forceSSL = mkDefault true;
        root = pkgs.jitsi-meet;
        extraConfig = ''
          ssi on;
        '';
        locations."@root_path".extraConfig = ''
          rewrite ^/(.*)$ / break;
        '';
        locations."~ ^/([^/\\?&:'\"]+)$".tryFiles = "$uri @root_path";
        locations."^~ /xmpp-websocket" = {
          priority = 100;
          proxyPass = "http://localhost:5280/xmpp-websocket";
          proxyWebsockets = true;
        };
        locations."=/http-bind" = {
          proxyPass = "http://localhost:5280/http-bind";
          extraConfig = ''
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header Host $host;
          '';
        };
        locations."=/external_api.js" = mkDefault {
          alias = "${pkgs.jitsi-meet}/libs/external_api.min.js";
        };
        # From original jitsi-meet.nix
        locations."=/_api/room-info" = {
          proxyPass = "http://localhost:5280/room-info";
          extraConfig = ''
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header Host $host;
          '';
        };
        locations."=/config.js" = mkDefault {
          alias = overrideJs "${pkgs.jitsi-meet}/config.js" "config" (recursiveUpdate defaultCfg cfg.config) cfg.extraConfig;
        };
        locations."=/interface_config.js" = mkDefault {
          alias = overrideJs "${pkgs.jitsi-meet}/interface_config.js" "interfaceConfig" cfg.interfaceConfig "";
        };
        locations."/socket.io/" = mkIf cfg.excalidraw.enable {
          proxyPass = "http://127.0.0.1:${toString cfg.excalidraw.port}";
          proxyWebsockets = true;
        };
      };
    };

    services.caddy = mkIf cfg.caddy.enable {
      enable = mkDefault true;
      virtualHosts.${cfg.hostName} = {
        extraConfig =
        let
          templatedJitsiMeet = pkgs.runCommand "templated-jitsi-meet" { } ''
            cp -R --no-preserve=all ${pkgs.jitsi-meet}/* .
            for file in *.html **/*.html ; do
              ${pkgs.sd}/bin/sd '<!--#include virtual="(.*)" -->' '{{ include "$1" }}' $file
            done
            rm config.js
            rm interface_config.js
            cp -R . $out
            cp ${overrideJs "${pkgs.jitsi-meet}/config.js" "config" (recursiveUpdate defaultCfg cfg.config) cfg.extraConfig} $out/config.js
            cp ${overrideJs "${pkgs.jitsi-meet}/interface_config.js" "interfaceConfig" cfg.interfaceConfig ""} $out/interface_config.js
            cp ./libs/external_api.min.js $out/external_api.js
          '';
        in ''
          handle /http-bind {
            header Host ${cfg.hostName}
            reverse_proxy 127.0.0.1:5280
          }
          handle /xmpp-websocket {
            reverse_proxy 127.0.0.1:5280
          }
          handle {
            templates
            root * ${templatedJitsiMeet}
            try_files {path} {path}
            try_files {path} /index.html
            file_server
          }
        '';
      };
    };

    services.jitsi-meet.config = recursiveUpdate
      (mkIf cfg.excalidraw.enable {
        whiteboard = {
          enabled = true;
          collabServerBaseUrl = "https://${cfg.hostName}";
        };
      })
      (mkIf cfg.secureDomain.enable {
        hosts.anonymousdomain = "guest.${cfg.hostName}";
      });

    services.jitsi-videobridge = mkIf cfg.videobridge.enable {
      enable = true;
      xmppConfigs."localhost" = {
        userName = "jvb";
        domain = "auth.${cfg.hostName}";
        passwordFile = "/var/lib/jitsi-meet/videobridge-secret";
        mucJids = "jvbbrewery@internal.auth.${cfg.hostName}";
        disableCertificateVerification = true;
      };
    };

    services.jicofo = mkIf cfg.jicofo.enable {
      enable = true;
      xmppHost = "localhost";
      xmppDomain = cfg.hostName;
      userDomain = "auth.${cfg.hostName}";
      userName = "focus";
      userPasswordFile = "/var/lib/jitsi-meet/jicofo-user-secret";
      componentPasswordFile = "/var/lib/jitsi-meet/jicofo-component-secret";
      bridgeMuc = "jvbbrewery@internal.auth.${cfg.hostName}";
      config = mkMerge [{
        jicofo.xmpp.service.disable-certificate-verification = true;
        jicofo.xmpp.client.disable-certificate-verification = true;
      }
        (lib.mkIf (config.services.jibri.enable || cfg.jibri.enable) {
          jicofo.jibri = {
            brewery-jid = "JibriBrewery@internal.auth.${cfg.hostName}";
            pending-timeout = "90";
          };
        })
        (lib.mkIf cfg.secureDomain.enable {
          jicofo = {
            authentication = {
              enabled = "true";
              type = "XMPP";
              login-url = cfg.hostName;
            };
            xmpp.client.client-proxy = "focus.${cfg.hostName}";
          };
        })];
    };

    services.jibri = mkIf cfg.jibri.enable {
      enable = true;

      xmppEnvironments."jitsi-meet" = {
        xmppServerHosts = [ "localhost" ];
        xmppDomain = cfg.hostName;

        control.muc = {
          domain = "internal.auth.${cfg.hostName}";
          roomName = "JibriBrewery";
          nickname = "jibri";
        };

        control.login = {
          domain = "auth.${cfg.hostName}";
          username = "jibri";
          passwordFile = "/var/lib/jitsi-meet/jibri-auth-secret";
        };

        call.login = {
          domain = "recorder.${cfg.hostName}";
          username = "recorder";
          passwordFile = "/var/lib/jitsi-meet/jibri-recorder-secret";
        };

        usageTimeout = "0";
        disableCertificateVerification = true;
        stripFromRoomDomain = "conference.";
      };
    };
  };

  meta.doc = ./jitsi-meet.md;
  meta.maintainers = lib.teams.jitsi.members;
}
