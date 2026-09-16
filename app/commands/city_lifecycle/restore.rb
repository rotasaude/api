require "open3"

# Restaura um dump de cidade (Plano 8), o inverso de Backup.
#
# Ordem das guardas, e por quê: status e quarentena primeiro (outro processo
# pode seguir servindo a cidade por até 2× o TTL do CityCatalog, mesmo depois
# do suspend), arquivo depois, e o DIGEST DA CHAVE por último — mas ainda antes
# de qualquer DDL. Restaurar dump de outra época devolve dado ilegível SEM
# erro: essa é a única guarda que transforma o engano em falha visível.
module CityLifecycle
  module Restore
    def self.call(city:, path:)
      unless city.status == "suspended"
        return Result.fail(:invalid_status, message: "cidade #{city.slug} precisa estar suspensa (status=#{city.status})")
      end
      if SuspensionGuard.suspended_recently?(city)
        return Result.fail(:suspension_too_recent,
                           message: "aguarde #{SuspensionGuard::QUIET_PERIOD.to_i} s depois da suspensão")
      end
      return Result.fail(:missing_file, message: "dump não encontrado: #{File.basename(path.to_s)}") unless File.file?(path.to_s)

      mismatch = key_digest_mismatch(city, path)
      return mismatch if mismatch

      url = URI.parse(city.database_url)
      env = { "PGPASSWORD" => URI::DEFAULT_PARSER.unescape(url.password.to_s) }
      sslmode = URI.decode_www_form(url.query.to_s).to_h["sslmode"]
      env["PGSSLMODE"] = sslmode if sslmode.present?

      CityConnection.forget(city.shard)

      out, status = Open3.capture2e(
        env,
        "pg_restore", "--clean", "--if-exists", "--no-owner", "--no-acl",
        "--host", url.host.to_s, "--port", (url.port || 5432).to_s,
        "--username", URI::DEFAULT_PARSER.unescape(url.user.to_s),
        "--dbname", url.path.delete_prefix("/"), path.to_s
      )
      unless status.success?
        return Result.fail(:restore_failed, message: CitySchema.redact(out.lines.last(3).join).strip)
      end

      Platform.audit("city.restored", city_id: city.id, file: File.basename(path.to_s))
      Result.ok(path: path.to_s)
    end

    # Dump anterior ao Plano 8 não tem o arquivo irmão: não dá para provar nada,
    # e recusar impediria restaurar backup legítimo. Passa, e o runbook manda
    # conferir na mão.
    def self.key_digest_mismatch(city, path)
      digest_path = "#{path}.key-digest"
      return nil unless File.file?(digest_path)

      recorded = File.read(digest_path).strip
      return nil if ActiveSupport::SecurityUtils.secure_compare(recorded, Digest::SHA256.hexdigest(city.encryption_key))

      Result.fail(:key_mismatch,
                  message: "o dump foi tirado com outro material de cifra desta cidade — restaurar devolveria " \
                           "dado ilegível sem erro. Confirme a chave da época antes de seguir.")
    end
    private_class_method :key_digest_mismatch
  end
end
