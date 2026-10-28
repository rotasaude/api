# Cria ou edita uma doença de notificação local (contrato §3; K2, K12(d)).
# Formato pela mesma regra da lista nacional (DiseaseList.validate, código
# `local_`, sem fontes); depois, colisão: o código já existe, ou algum CID-10
# (prefixo de um lado ou do outro) / CIAP-2 (exato) já pertence à versão da
# plataforma em vigor ou a outra doença local ativa → 409 duplicate_code com o
# `path` do que colide. Texto longo ou inválido é recusado, nunca cortado.
# Desativar não confere colisão: a inativa fora da correspondência.
module Surveillance
  module SaveLocalDisease
    FIELDS = %w[name deadline cid10 ciap2 repeat_after_days].freeze
    LOCK_KEY = Zlib.crc32("local_notifiable_diseases")

    module_function

    # attrs: corpo JSON (chaves texto). Na edição só as chaves presentes mudam e
    # `code` não muda. -> Result.ok(disease: LocalNotifiableDisease, created:) |
    # fail(:invalid_disease, details: { path: }) | fail(:duplicate_code, details: { path: }).
    def call(attrs:, by:, disease: nil)
      attrs = attrs.to_h.stringify_keys
      created = disease.nil?
      merged = merge(attrs, disease)
      refusal = format_refusal(merged, attrs, disease)
      return refusal if refusal

      LocalNotifiableDisease.transaction do
        LocalNotifiableDisease.connection.execute("SELECT pg_advisory_xact_lock(#{LOCK_KEY})")
        clash = merged["active"] ? collision(merged, disease) : nil
        next clash if clash

        record = disease || LocalNotifiableDisease.new(code: merged["code"])
        record.assign_attributes(merged.slice(*FIELDS, "active").merge("updated_by_user" => by))
        if record.new_record? || record.changed?
          record.save!
          DomainEvents.publish("local_disease.changed",
                               local_disease_id: record.id, user_id: by.id)
        end
        Result.ok(disease: record, created: created)
      end
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:duplicate_code, details: { path: "code" })
    end

    def merge(attrs, disease)
      base = disease ? disease.attributes.slice("code", *FIELDS, "active") : { "active" => true }
      base.merge(attrs.slice("code", *FIELDS, "active"))
    end

    def format_refusal(merged, attrs, disease)
      return invalid("code") if disease && attrs.key?("code") && attrs["code"] != disease.code
      return invalid("active") unless [ true, false ].include?(merged["active"])

      result = DiseaseList.validate([ merged.slice("code", *FIELDS) ], code_rule: Catalog::LOCAL_CODE, require_sources: false)
      invalid(result.details[:path].delete_prefix("diseases.0.")) if result.failure?
    end

    # Primeira colisão: código, depois CID-10 (na ordem do corpo), depois CIAP-2.
    def collision(merged, disease)
      return duplicate("code") if LocalNotifiableDisease.where(code: merged["code"]).where.not(id: disease&.id).exists?

      others = LocalNotifiableDisease.active_diseases.where.not(id: disease&.id)
      owners = Diseases.platform.map { |d| [ d.cid10, d.ciap2 ] } + others.map { |o| [ o.cid10, o.ciap2 ] }
      taken_cid = owners.flat_map(&:first)
      taken_ciap = owners.flat_map(&:last)
      merged["cid10"].each_with_index do |c, j|
        return duplicate("cid10.#{j}") if taken_cid.any? { |o| c.start_with?(o) || o.start_with?(c) }
      end
      merged["ciap2"].each_with_index do |c, j|
        return duplicate("ciap2.#{j}") if taken_ciap.include?(c)
      end
      nil
    end

    def invalid(path) = Result.fail(:invalid_disease, details: { path: path })
    def duplicate(path) = Result.fail(:duplicate_code, details: { path: path })
    private_class_method :merge, :format_refusal, :collision, :invalid, :duplicate
  end
end
