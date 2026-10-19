# Nome do órgão de saúde e brasão da cidade, pelo operador no console (spec
# identidade da cidade). Valida TUDO antes de escrever: nome inválido ou brasão
# recusado não grava nada. health_department_name: :keep não mexe; "" limpa.
# O brasão vira blob já `analyzed`, para anexar não enfileirar AnalyzeJob, e o
# antigo sai por purge SÍNCRONO: jobs do Active Storage não herdam de
# ApplicationJob e furariam o PlatformQueue.check!.
# Reasons: :invalid_health_department_name, :too_large, :invalid_format, :invalid_dimensions.
class UpdateCityIdentity
  def self.call(city:, health_department_name: :keep, coat_of_arms: nil, remove_coat_of_arms: false)
    name = health_department_name
    name = nil if name == ""
    unless name == :keep || name.nil? || (name.is_a?(String) && name.length <= City::HEALTH_DEPARTMENT_NAME_MAX)
      return Result.fail(:invalid_health_department_name)
    end

    # Parte multipart vazia (nenhum arquivo escolhido) = sem mudança; valor que
    # não é arquivo (string, hash) = formato inválido, nunca 500.
    coat_of_arms = nil if coat_of_arms.respond_to?(:blank?) && coat_of_arms.blank? && !coat_of_arms.respond_to?(:read)
    return Result.fail(:invalid_format) if coat_of_arms && !coat_of_arms.respond_to?(:read)

    check = nil
    if coat_of_arms
      check = CityIdentity::CoatOfArmsCheck.call(coat_of_arms)
      return Result.fail(check.reason) unless check.ok?

      coat_of_arms.rewind # o check lê do ponto atual e não rebobina
    end

    blob = check && build_blob(coat_of_arms, check.payload)
    old_blob = (city.coat_of_arms.blob if city.coat_of_arms.attached? && (blob || remove_coat_of_arms))

    changed = []
    previous_name = city.health_department_name
    begin
      if name != :keep && name != previous_name
        city.update!(health_department_name: name) # plataforma
        changed << "health_department_name"
      end
      if blob || old_blob
        # O Active Storage tem pool próprio (ActiveStorage::Record): a troca
        # do anexo só é atômica dentro da transação DELE.
        ActiveStorage::Record.transaction do
          city.coat_of_arms.detach if old_blob
          city.coat_of_arms.attach(blob) if blob
        end
        changed << "coat_of_arms"
      end
    rescue StandardError
      discard_blob(blob)
      city.update_columns(health_department_name: previous_name) if changed.include?("health_department_name")
      raise
    end

    purge_old(old_blob)
    changed.sort!

    if changed.any?
      fields = { city_id: city.id, fields: changed }
      fields[:coat_of_arms_checksum] = city.coat_of_arms.attached? ? city.coat_of_arms.blob.checksum : nil if changed.include?("coat_of_arms")
      Platform.audit("city.identity_updated", **fields)
    end
    Result.ok(city: city, changed: changed)
  end

  # Blob novo de uma escrita que falhou: purge síncrono, sem esconder o erro original.
  def self.discard_blob(blob)
    blob&.purge
  rescue StandardError => e
    Rails.logger.warn("UpdateCityIdentity: blob novo órfão após falha (#{e.class})")
  end

  # Blob antigo só sai depois do sucesso; se o storage falhar, fica órfão em vez de dar 500.
  def self.purge_old(blob)
    blob&.purge
  rescue StandardError => e
    Rails.logger.warn("UpdateCityIdentity: blob antigo não purgado (#{e.class})")
  end

  def self.build_blob(io, payload)
    ActiveStorage::Blob.create_and_upload!(
      io: io, filename: "coat_of_arms.#{payload[:content_type] == 'image/webp' ? 'webp' : 'png'}",
      content_type: payload[:content_type], identify: false,
      metadata: { analyzed: true, identified: true, width: payload[:width], height: payload[:height] }
    )
  end

  private_class_method :build_blob, :discard_blob, :purge_old
end
