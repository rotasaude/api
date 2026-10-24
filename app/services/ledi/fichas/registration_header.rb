# Cabeçalho das fichas de cadastro (módulo 24a, ADR 0042; contrato §15.1;
# plano, Desvio 4): UnicaLotacaoHeader com o CNS e o CBO de quem gravou (o
# vínculo dele NA equipe), o INE da equipe, o CNES da unidade da equipe, o
# instante da versão e o IBGE do perfil da cidade. Sem dado do cidadão.
module Ledi
  module Fichas
    RegistrationHeader = Data.define(:cnes, :ine, :professional_cns, :cbo, :saved_at, :ibge_code) do
      def to_thrift
        Ledi::Version.load!
        Br::Gov::Saude::Esusab::Ras::Common::UnicaLotacaoHeaderThrift.new(
          profissionalCNS: professional_cns, cboCodigo_2002: cbo, cnes: cnes, ine: ine.presence,
          dataAtendimento: (saved_at.to_f * 1000).to_i, codigoIbgeMunicipio: ibge_code
        )
      end

      # "AAAAMM" do instante da versão, no fuso da cidade.
      def competence = saved_at.in_time_zone.strftime("%Y%m")
    end
  end
end
