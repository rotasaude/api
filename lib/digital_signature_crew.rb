# Semente de dev da assinatura digital (ADR 0032; Task 18). Dev é fictício mas
# imita o real: só Curitiba liga, e liga os DOIS interruptores (digital_signature
# e o PSC simulado signature_psc_mock) com o mantenedor de dev, pelo mesmo
# caminho do maintenance. Garante CPF com dígito válido nos profissionais que
# não têm. O vínculo do certificado e a sessão do turno são feitos no navegador.
# Roda depois do ClinicalRecordCrew (que liga o prontuário).
module DigitalSignatureCrew
  DEV_MAINTAINER = "dev@local".freeze
  SWITCHES = %w[digital_signature signature_psc_mock].freeze

  module_function

  def seed_current_city(slug:)
    return { switch: "desligado (só Curitiba liga)", professionals: [] } unless slug == "curitiba"

    maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
    unless maintainer
      warn "[seeds] assinatura digital: sem mantenedor de dev (#{DEV_MAINTAINER}) — interruptores não ligados"
      return { switch: "desligado (sem mantenedor)", professionals: [] }
    end

    city = City.find(Current.city.id)
    SWITCHES.each { |key| Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer) }
    professionals = Professional.where(cpf: nil).order(:id).each_with_index.map do |professional, index|
      professional.update!(cpf: cpf_from(900_000_000 + index))
      professional.professional_name
    end
    missing = SWITCHES.flat_map { |key| Platform::Features.missing(city, key) }
    { switch: missing.empty? ? "ligado" : "ligado, falta: #{missing.join(', ')}", professionals: professionals }
  end

  # CPF fictício com dígitos verificadores válidos a partir de 9 dígitos.
  def cpf_from(base)
    digits = format("%09d", base).chars.map(&:to_i)
    2.times do
      weights = (digits.size + 1).downto(2).to_a
      sum = digits.zip(weights).sum { |digit, weight| digit * weight }
      digits << ((sum * 10) % 11) % 10
    end
    digits.join
  end
end
