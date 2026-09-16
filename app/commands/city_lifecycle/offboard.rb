# Desliga uma cidade (spec banco-por-cidade §4): suspensa → dump final → canais
# inativos e grants apagados → archived → DROP DATABASE e DROP ROLE.
#
# O dump vem antes de tudo: se falhar, nada muda. archived vem antes do drop: se
# o drop falhar, a cidade já não é servida nem migrada, e rodar de novo numa
# cidade archived só repete o drop (idempotente). Entregar o dump à prefeitura
# fica fora do sistema.
#
# Duas corridas que apagariam dado fora do dump final:
#   - Período de espera: os outros processos web ainda servem a cidade suspensa
#     por até CityCatalog::CACHE_TTL. Enquanto o último city.suspended for mais
#     novo que QUIET_PERIOD (o TTL duas vezes), recusa antes de fazer o dump.
#     Cidade suspensa fora do CityLifecycle::Suspend (sem evento) passa. A
#     checagem em si mora em CityLifecycle::SuspensionGuard — city:rekey e
#     city:rotate_key (lib/tasks/city.rake) precisam da MESMA regra (fix F1),
#     então este módulo só reusa QUIET_PERIOD/suspended_recently? de lá em vez
#     de manter uma cópia.
#   - Transição guardada: um city:resume durante o dump não é sobrescrito. A
#     linha só vira archived se AINDA estiver suspended, na mesma transação dos
#     canais, grants e auditoria; senão nada muda, nada é apagado e o dump já
#     feito fica (caminho em details).
#
# Cidades de dev criadas por city:dev_up (banco do superusuário de bootstrap) não
# são apagáveis por rota_provisioner: o resultado é :drop_failed, com a cidade já
# archived e o banco intacto.
module CityLifecycle
  module Offboard
    QUIET_PERIOD = SuspensionGuard::QUIET_PERIOD

    def self.call(city:, backup_dir:)
      return drop(city, backup_path: nil) if city.status == "archived"

      unless city.status == "suspended"
        return Result.fail(:invalid_status, message: "cidade #{city.slug} precisa estar suspended (status=#{city.status})")
      end

      if SuspensionGuard.suspended_recently?(city)
        return Result.fail(:suspension_too_recent, message: "aguarde #{QUIET_PERIOD.to_i} s depois da suspensão")
      end

      backup = Backup.call(city: city, dir: backup_dir)
      return backup if backup.failure?

      backup_path = backup.payload[:path]
      archived = false
      PlatformRecord.transaction do
        guard = City.where(id: city.id, status: "suspended").update_all(status: "archived", updated_at: Time.current)
        raise ActiveRecord::Rollback if guard.zero?

        CityChannel.where(city_id: city.id).update_all(active: false, updated_at: Time.current)
        CityGrant.where(city_id: city.id).delete_all
        Platform.audit("city.archived", city_id: city.id, backup: File.basename(backup_path))
        archived = true
      end
      unless archived
        return Result.fail(:invalid_status, message: "cidade #{city.slug} mudou de status durante a operação",
                                            details: { backup_path: backup_path })
      end

      city.reload
      CityCatalog.reset_cache!

      drop(city, backup_path: backup_path)
    end

    def self.drop(city, backup_path:)
      CityConnection.forget(city.shard)
      CityDatabase.drop!(slug: city.slug)
      Result.ok(city: city, backup_path: backup_path)
    rescue PG::Error => e
      Result.fail(:drop_failed, message: CitySchema.redact(e.message))
    end
    private_class_method :drop
  end
end
