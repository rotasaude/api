# Desliga uma cidade (spec banco-por-cidade §4): suspensa → dump final → canais
# inativos e grants apagados → archived → DROP DATABASE e DROP ROLE.
#
# O dump vem antes de tudo: se falhar, nada muda. archived vem antes do drop: se
# o drop falhar, a cidade já não é servida nem migrada, e rodar de novo numa
# cidade archived só repete o drop (idempotente). Entregar o dump à prefeitura
# fica fora do sistema.
#
# Cidades de dev criadas por city:dev_up (banco do superusuário de bootstrap) não
# são apagáveis por rota_provisioner: o resultado é :drop_failed, com a cidade já
# archived e o banco intacto.
module CityLifecycle
  module Offboard
    def self.call(city:, backup_dir:)
      return drop(city, backup_path: nil) if city.status == "archived"

      unless city.status == "suspended"
        return Result.fail(:invalid_status, message: "cidade #{city.slug} precisa estar suspended (status=#{city.status})")
      end

      backup = Backup.call(city: city, dir: backup_dir)
      return backup if backup.failure?

      PlatformRecord.transaction do
        CityChannel.where(city_id: city.id).update_all(active: false, updated_at: Time.current)
        CityGrant.where(city_id: city.id).delete_all
        city.update!(status: "archived")
        Platform.audit("city.archived", city_id: city.id, backup: File.basename(backup.payload[:path]))
      end
      CityCatalog.reset_cache!

      drop(city, backup_path: backup.payload[:path])
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
