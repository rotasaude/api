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

    check = nil
    if coat_of_arms
      check = CityIdentity::CoatOfArmsCheck.call(coat_of_arms)
      return Result.fail(check.reason) unless check.ok?

      coat_of_arms.rewind # o check lê do ponto atual e não rebobina
    end

    blob = check && build_blob(coat_of_arms, check.payload)
    old_blob = (city.coat_of_arms.blob if city.coat_of_arms.attached? && (blob || remove_coat_of_arms))

    changed = []
    ActiveRecord::Base.transaction do
      if name != :keep && name != city.health_department_name
        city.health_department_name = name
        changed << "health_department_name"
      end
      city.coat_of_arms.detach if old_blob
      city.coat_of_arms.attach(blob) if blob
      changed << "coat_of_arms" if blob || old_blob
      city.save!
    end
    old_blob&.purge
    changed.sort!

    if changed.any?
      Platform.audit("city.identity_updated", city_id: city.id, fields: changed,
                                             coat_of_arms_checksum: city.coat_of_arms.attached? ? city.coat_of_arms.blob.checksum : nil)
    end
    Result.ok(city: city, changed: changed)
  end

  def self.build_blob(io, payload)
    ActiveStorage::Blob.create_and_upload!(
      io: io, filename: "coat_of_arms.#{payload[:content_type] == 'image/webp' ? 'webp' : 'png'}",
      content_type: payload[:content_type], identify: false,
      metadata: { analyzed: true, identified: true, width: payload[:width], height: payload[:height] }
    )
  end

  private_class_method :build_blob
end
