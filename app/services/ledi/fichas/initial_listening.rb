# Escuta inicial por nível superior como Atendimento Individual (ADR 0030;
# spec §5; Task 1): tipoAtendimento 4, local UBS, conduta pelo destino,
# queixa CIAP-2 como problema avaliado, medições, CPF do cidadão (CNS não vai
# junto: são exclusivos). Implementa Ledi::Ficha.
module Ledi
  module Fichas
    class InitialListening
      ORIGIN_THIRD_PARTY = 3
      M = Ledi::ScreeningMapping

      attr_reader :identity, :revision, :destination, :source_id

      def initialize(identity:, revision:, destination:, source_id:)
        @identity, @revision, @destination, @source_id = identity, revision, destination, source_id
      end

      def type = "atendimento_individual"
      def competence = identity.started_at.in_time_zone.strftime("%Y%m")
      def cnes = identity.cnes
      def ine = identity.ine
      def source = { type: "Screening", id: source_id }

      def to_thrift(uuid:)
        Ledi::Version.load!
        common = Br::Gov::Saude::Esusab::Ras::Common
        ai = Br::Gov::Saude::Esusab::Ras::Atendindividual
        header = common::VariasLotacoesHeaderThrift.new(
          lotacaoFormPrincipal: common::LotacaoHeaderThrift.new(profissionalCNS: identity.professional_cns,
                                                                cboCodigo_2002: identity.cbo, cnes: identity.cnes,
                                                                ine: identity.ine),
          dataAtendimento: ms(identity.started_at), codigoIbgeMunicipio: identity.ibge_code
        )
        child = ai::FichaAtendimentoIndividualChildThrift.new(
          dataNascimento: ms(identity.birth_date.in_time_zone), localDeAtendimento: M.value("initial_listening.local_de_atendimento"),
          sexo: M.sex_code(identity.sex), turno: M.turno(identity.started_at),
          tipoAtendimento: M.value("initial_listening.tipo_atendimento"), condutas: [ M.conduta(destination) ],
          dataHoraInicialAtendimento: ms(identity.started_at), dataHoraFinalAtendimento: ms(identity.ended_at),
          cpfCidadao: identity.citizen_cpf, stCidadaoNaoPossuiCpf: false, ficouEmObservacao: false,
          medicoes: Medicoes.build(revision),
          problemasCondicoes: [ common::ProblemaCondicaoThrift.new(ciap: revision.ciap2_code, isAvaliado: true) ]
        )
        ai::FichaAtendimentoIndividualMasterThrift.new(uuidFicha: uuid, tpCdsOrigem: ORIGIN_THIRD_PARTY,
                                                       headerTransport: header, atendimentosIndividuais: [ child ])
      end

      private

      def ms(time) = (time.to_f * 1000).to_i
    end
  end
end
