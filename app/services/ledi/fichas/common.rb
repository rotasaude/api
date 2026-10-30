# app/services/ledi/fichas/common.rb
# Peças comuns ao Atendimento Individual (FAI) e ao Atendimento Odontológico
# (FAO): o cabeçalho de várias lotações, o problema avaliado, os exames
# solicitados e a data em milissegundos (Epoch, como pede o layout). Puras.
module Ledi
  module Fichas
    module Common
      module_function

      def thrift
        Ledi::Version.load!
        Br::Gov::Saude::Esusab::Ras::Common
      end

      def header(identity)
        thrift::VariasLotacoesHeaderThrift.new(
          lotacaoFormPrincipal: thrift::LotacaoHeaderThrift.new(profissionalCNS: identity.professional_cns,
                                                                cboCodigo_2002: identity.cbo, cnes: identity.cnes,
                                                                ine: identity.ine),
          dataAtendimento: ms(identity.started_at), codigoIbgeMunicipio: identity.ibge_code
        )
      end

      # Regra LEDI: dataInicioProblema >= nascimento (início com precisão de mês
      # ou ano grava o dia 1, que pode cair antes do nascimento).
      def problem(p, birth_date)
        thrift::ProblemaCondicaoThrift.new(
          uuidProblema: p.uuid, uuidEvolucaoProblema: p.evolution_uuid, coSequencialEvolucao: p.sequence, ciap: p.ciap,
          cid10: p.cid10, situacao: p.situation, dataInicioProblema: p.onset_on && ms([ p.onset_on, birth_date ].max.in_time_zone),
          dataFimProblema: p.resolved_on && ms(p.resolved_on.in_time_zone), isAvaliado: true
        )
      end

      # Exames solicitados ("S"); sem nenhum, o campo fica fora.
      def exams(codes)
        return nil if codes.empty?

        codes.map { |code| thrift::ExameThrift.new(codigoExame: code, solicitadoAvaliado: [ Ledi::ConsultationMapping.exam_requested ]) }
      end

      def ms(time) = (time.to_f * 1000).to_i
    end
  end
end
