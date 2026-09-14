# Fase 1 do provisionamento em duas fases (spec banco-por-cidade §4, Plano 4):
# registra a cidade no catálogo como `provisioning` e enfileira o ProvisionCityJob,
# que cria banco e role, migra, semeia e ativa. O processo web não cria banco —
# só o worker, com a credencial de rota_provisioner.
#
# A senha do role da cidade nasce aqui e fica no catálogo (database_url cifrada):
# todo retry do job usa a mesma.
#
# Idempotente: repetir com o slug de uma cidade ainda em provisioning reenfileira
# o job para ela — é assim que se retoma um provisionamento que falhou. Slug de
# cidade em qualquer outro estado → :city_exists.
class ProvisionCity
  UF = /\A[A-Z]{2}\z/
  IBGE_CODE = /\A\d{7}\z/

  def self.call(slug:, name:, uf:, ibge_code:, admin_email:, alert_email:, by:)
    new(slug: slug, name: name, uf: uf, ibge_code: ibge_code, admin_email: admin_email,
        alert_email: alert_email, by: by).call
  end

  def initialize(slug:, name:, uf:, ibge_code:, admin_email:, alert_email:, by:)
    @slug, @name, @uf, @ibge_code = slug, name, uf, ibge_code
    @admin_email, @alert_email, @by = admin_email, alert_email, by
  end

  def call
    errors = validation_errors
    return Result.fail(:invalid, message: errors.join(", ")) if errors.any?

    city = City.find_by(slug: @slug)
    if city && city.status != "provisioning"
      return Result.fail(:city_exists, message: "cidade #{@slug} já existe (status=#{city.status})")
    end

    city ||= City.create!(slug: @slug, name: @name, uf: @uf, status: "provisioning",
                          database_url: CityDatabase.url_for(slug: @slug, password: SecureRandom.hex(24)),
                          encryption_key: SecureRandom.hex(32))

    ProvisionCityJob.perform_later(city_id: city.id, ibge_code: @ibge_code, admin_email: @admin_email,
                                   alert_email: @alert_email, operator_id: @by.id)
    Result.ok(city: city)
  rescue ActiveRecord::RecordInvalid => e
    Result.fail(:invalid, message: e.record.errors.full_messages.join(", "))
  rescue ActiveRecord::RecordNotUnique
    Result.fail(:city_exists, message: "cidade #{@slug} já existe")
  end

  private

  def validation_errors
    [].tap do |errors|
      errors << "slug inválido" unless CityDatabase.valid_slug?(@slug)
      errors << "name obrigatório" unless @name.is_a?(String) && @name.present?
      errors << "uf inválida" unless string_matching?(@uf, UF)
      errors << "ibge_code inválido" unless string_matching?(@ibge_code, IBGE_CODE)
      errors << "admin_email inválido" unless string_matching?(@admin_email, URI::MailTo::EMAIL_REGEXP)
      errors << "alert_email inválido" unless string_matching?(@alert_email, URI::MailTo::EMAIL_REGEXP)
    end
  end

  def string_matching?(value, pattern)
    value.is_a?(String) && value.match?(pattern)
  end
end
