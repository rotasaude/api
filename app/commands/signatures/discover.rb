# app/commands/signatures/discover.rb
# Localização do titular por CPF em cada PSC habilitado (ADR 0032; spec §5;
# serviço obrigatório do DOC-ICP-17.01). PSC fora do ar não derruba a lista.
# Os PSC são os da cidade (interruptor signature_psc_mock: só o simulado).
module Signatures
  module Discover
    module_function

    def call(user:)
      cpf = user.professional&.cpf
      return Result.fail(:professional_cpf_missing) if cpf.blank?

      providers = []
      unavailable = []
      Providers.configured.each do |provider|
        providers << { provider: provider.key, found: Psc::Client.new(provider).discover(cpf) }
      rescue Psc::Error
        unavailable << provider.key
      end
      Result.ok(providers: providers, unavailable: unavailable)
    end
  end
end
