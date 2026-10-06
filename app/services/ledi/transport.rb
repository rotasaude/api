# Camada de transporte LEDI (spec §6.2): embrulha a ficha serializada num
# DadoTransporteThrift e devolve o binário que vai para o PEC. O codIbge vem do
# city_profile da cidade (fonte única; decisão do coordenador do módulo 16).
# Precisa rodar na conexão da cidade (CityConnection.with / request / job).
module Ledi
  module Transport
    class IbgeMissing < StandardError; end

    module_function

    def wrap(ficha, city:, uuid:)
      Ledi::Version.load!
      ibge = CityProfile.current&.ibge_code
      raise IbgeMissing, "city_profile sem ibge_code" if ibge.blank?

      sender = Ledi::Sender.installation(city)
      transport = Br::Gov::Saude::Esusab::Dadotransp::DadoTransporteThrift.new(
        uuidDadoSerializado: uuid,
        tipoDadoSerializado: Ledi::FichaTypes.code(ficha.type),
        cnesDadoSerializado: ficha.cnes,
        codIbge: ibge,
        ineDadoSerializado: ficha.ine.presence,
        dadoSerializado: Ledi::Version.serialize(ficha.to_thrift(uuid: uuid)),
        remetente: sender,
        originadora: sender,
        versao: Ledi::Version.thrift
      )
      Ledi::Version.serialize(transport)
    end

    def read(bytes) = Ledi::Version.deserialize(Br::Gov::Saude::Esusab::Dadotransp::DadoTransporteThrift, bytes)

    # Reenvio com uuid novo (Ledi::Resend, quando a prova mandar): o uuid vive
    # no transporte E dentro da ficha; os dois mudam juntos.
    def rewrap(bytes, uuid:)
      transport = read(bytes)
      type = Ledi::FichaTypes.type_for_code(transport.tipoDadoSerializado)
      inner = Ledi::Version.deserialize(Ledi::FichaTypes.klass(type), transport.dadoSerializado)
      inner.public_send(:"#{Ledi::FichaTypes.uuid_field(type)}=", uuid)
      transport.uuidDadoSerializado = uuid
      transport.dadoSerializado = Ledi::Version.serialize(inner)
      Ledi::Version.serialize(transport)
    end
  end
end
