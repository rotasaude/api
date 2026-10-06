# Remetente e originadora do transporte LEDI: o software Rota Saúde, numa
# "instalação" por cidade (uuidInstalacao estável, derivado do id da cidade).
module Ledi
  module Sender
    class Missing < StandardError; end

    NAMESPACE = "6f1c3d1e-2b7a-5c4e-9a8d-0e5f4b3a2c10"
    SOFTWARE = "Rota Saúde"

    module_function

    def software_version = ENV.fetch("APP_VERSION", "dev")

    def installation(city)
      Ledi::Version.load!
      config = Rails.application.config_for(:ledi)
      cnpj, name = config[:sender_cnpj].to_s, config[:sender_name].to_s
      raise Missing, "LEDI_SENDER_CNPJ/LEDI_SENDER_NAME ausentes" if cnpj.blank? || name.blank?

      Br::Gov::Saude::Esusab::Dadotransp::DadoInstalacaoThrift.new(
        contraChave: "#{SOFTWARE} - #{software_version}",
        uuidInstalacao: Digest::UUID.uuid_v5(NAMESPACE, city.id.to_s),
        cpfOuCnpj: cnpj, nomeOuRazaoSocial: name,
        email: config[:sender_email].presence, fone: config[:sender_phone].presence,
        versaoSistema: software_version
      )
    end
  end
end
