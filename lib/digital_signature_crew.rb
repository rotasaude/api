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
    professionals = Professional.where(cpf: nil).order(:id).map do |professional|
      professional.update!(cpf: free_cpf_for(slug, professional))
      professional.professional_name
    end
    missing = SWITCHES.flat_map { |key| Platform::Features.missing(city, key) }
    { switch: missing.empty? ? "ligado" : "ligado, falta: #{missing.join(', ')}", professionals: professionals }
  end

  # CPF fictício estável por profissional (hash de slug + id), com dígitos
  # verificadores válidos; pula candidatos já em uso (reexecução idempotente).
  def free_cpf_for(slug, professional)
    (0..).each do |attempt|
      base = Digest::SHA256.hexdigest("digital-signature:#{slug}:#{professional.id}:#{attempt}").scan(/\d/).join[0, 9].ljust(9, "1")
      next if base.chars.uniq.size == 1

      nums = base.chars.map(&:to_i)
      first = CitizenIdentity::Cpf.check_digit(nums)
      cpf = base + first.to_s + CitizenIdentity::Cpf.check_digit(nums + [ first ]).to_s
      return cpf unless Professional.exists?(cpf: cpf)
    end
  end
end
