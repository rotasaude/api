# app/services/ledi/version.rb
# Layout LEDI APS ativo (ADR 0028). As classes Thrift moram em
# vendor/ledi/<versão>/gen-rb, geradas por bin/ledi-generate dos IDLs oficiais;
# o vendor não é autoload do Zeitwerk (o código gerado usa `require` por nome de
# arquivo), então entra no $LOAD_PATH aqui, uma vez. Trocar de versão = gerar a
# pasta nova, rodar spec/services/ledi/contract_spec.rb e mudar ACTIVE.
module Ledi
  module Version
    ACTIVE = "8.7.0"
    TYPES = %w[dado_transporte_types ficha_atendimento_procedimento_types ficha_atendimento_individual_types].freeze
    LOCK = Mutex.new

    module_function

    def root = Rails.root.join("vendor/ledi", ACTIVE)

    def load!
      LOCK.synchronize do
        return if @loaded
        gen = root.join("gen-rb").to_s
        $LOAD_PATH.unshift(gen) unless $LOAD_PATH.include?(gen)
        require "thrift"
        TYPES.each { |file| require file }
        @loaded = true
      end
    end

    def thrift
      load!
      major, minor, revision = ACTIVE.split(".").map(&:to_i)
      Br::Gov::Saude::Esusab::Dadotransp::VersaoThrift.new(major: major, minor: minor, revision: revision)
    end

    def serialize(struct)
      load!
      Thrift::Serializer.new(Thrift::BinaryProtocolFactory.new).serialize(struct).b
    end

    def deserialize(klass, bytes)
      load!
      Thrift::Deserializer.new(Thrift::BinaryProtocolFactory.new).deserialize(klass.new, bytes)
    end
  end
end
