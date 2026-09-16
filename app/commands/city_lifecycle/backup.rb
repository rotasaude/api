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

      # umask é do PROCESSO inteiro, não da thread (POSIX) — trocar aqui e
      # restaurar no ensure é seguro porque city:backup roda como rake task
      # isolada no worker/CLI (kamal app exec --roles=worker), nunca dentro do
      # servidor web multi-thread: não há requisição concorrente para vazar
      # umask entre threads.
      #
      # Sem isso, pg_dump cria o arquivo com o umask herdado do processo
      # (tipicamente 022): group/world-readable durante TODA a escrita do
      # dump, não só até o chmod 0600 abaixo — uma janela real, já que o dump
      # de uma cidade pode levar segundos. 0600 aqui é só para não sermos mais
      # permissivos que o final; nada nasce group/other-writable de qualquer
      # forma.
      previous_umask = File.umask(0o077)
      begin
        out, status = Open3.capture2e(
          env,
          "pg_dump", "--format=custom", "--no-owner", "--no-acl",
          "--host", url.host.to_s, "--port", (url.port || 5432).to_s,
          "--username", URI::DEFAULT_PARSER.unescape(url.user.to_s), "--dbname", url.path.delete_prefix("/"),
          "--file", path
        )
      ensure
        File.umask(previous_umask)
      end
      unless status.success?
        # Falha deixa um dump parcial: mesma limpeza de antes (rm_f), só que
        # agora o parcial também nasceu 0600 (umask acima) enquanto existiu.
        FileUtils.rm_f(path)
        return Result.fail(:backup_failed, message: CitySchema.redact(out.lines.last(3).join).strip)
      end
      File.chmod(0o600, path) # cinto e suspensório: o umask acima já garante isto.

      # Plano 8: o digest do material da cidade no momento do dump. É o que
      # permite ao city:restore RECUSAR um dump de outra época — sem ele, a
      # restauração devolve dado ilegível sem erro nenhum.
      digest_path = "#{path}.key-digest"
      File.write(digest_path, Digest::SHA256.hexdigest(city.encryption_key), perm: 0o600)

      Platform.audit("city.backed_up", city_id: city.id, file: File.basename(path))
      Result.ok(path: path, key_digest_path: digest_path)
    end
  end
end
