require "open3"

# Dump de UMA cidade (spec banco-por-cidade §4): pg_dump em formato custom, sem dono
# nem ACL, restaurável sozinho num banco vazio com pg_restore --no-owner.
#
# Conecta com o role da própria cidade (só enxerga o banco dela). A senha vai por
# PGPASSWORD, nunca na linha de comando; o sslmode da URL vai por PGSSLMODE. Os
# dados cifrados (AR encryption) seguem cifrados no dump: restaurar exige as
# chaves — por cidade no Plano 6. Diretório 0700 e dump 0600.
module CityLifecycle
  module Backup
    STATUSES = %w[active suspended].freeze

    def self.call(city:, dir:)
      unless STATUSES.include?(city.status)
        return Result.fail(:invalid_status, message: "cidade #{city.slug} sem banco para dump (status=#{city.status})")
      end

      url = URI.parse(city.database_url)
      env = { "PGPASSWORD" => URI::DEFAULT_PARSER.unescape(url.password.to_s) }
      sslmode = URI.decode_www_form(url.query.to_s).to_h["sslmode"]
      env["PGSSLMODE"] = sslmode if sslmode.present?

      FileUtils.mkdir_p(dir, mode: 0o700)
      path = File.join(dir.to_s, "#{city.slug}-#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}.dump")

      out, status = Open3.capture2e(
        env,
        "pg_dump", "--format=custom", "--no-owner", "--no-acl",
        "--host", url.host.to_s, "--port", (url.port || 5432).to_s,
        "--username", URI::DEFAULT_PARSER.unescape(url.user.to_s), "--dbname", url.path.delete_prefix("/"),
        "--file", path
      )
      unless status.success?
        FileUtils.rm_f(path)
        return Result.fail(:backup_failed, message: CitySchema.redact(out.lines.last(3).join).strip)
      end
      File.chmod(0o600, path)

      Platform.audit("city.backed_up", city_id: city.id, file: File.basename(path))
      Result.ok(path: path)
    end
  end
end
