# app/services/cnes/base_layout.rb
# Layout da base mensal do CNES (BASE_DE_DADOS_CNES_AAAAMM.ZIP; pesquisa frente
# 2; desvio 10): CSV com ";" e ISO-8859-1, lido por NOME de coluna. Se o
# dicionário oficial nomear diferente, muda só aqui. O município no CNES tem
# 6 dígitos (IBGE sem o verificador).
module Cnes
  module BaseLayout
    ENCODING = "ISO-8859-1".freeze
    FILES = {
      establishments: /\AtbEstabelecimento\d{6}\.csv\z/i,
      teams: /\AtbEquipe\d{6}\.csv\z/i,
      team_bonds: /\ArlEstabEquipeProf\d{6}\.csv\z/i,
      unit_bonds: /\AtbCargaHorariaSus\d{6}\.csv\z/i,
      professionals: /\AtbDadosProfissionalSus\d{6}\.csv\z/i
    }.freeze
    ESTABLISHMENT = { unit_id: "CO_UNIDADE", cnes: "CO_CNES", name: "NO_FANTASIA", unit_type: "TP_UNIDADE",
                      municipality: "CO_MUNICIPIO_GESTOR" }.freeze
    TEAM = { municipality: "CO_MUNICIPIO", area: "CO_AREA", seq: "SEQ_EQUIPE", kind: "TP_EQUIPE", unit_id: "CO_UNIDADE",
             ine: "CO_EQUIPE", name: "NO_REFERENCIA", deactivated_on: "DT_DESATIVACAO" }.freeze
    TEAM_BOND = { municipality: "CO_MUNICIPIO", area: "CO_AREA", seq: "SEQ_EQUIPE", unit_id: "CO_UNIDADE",
                  professional_id: "CO_PROFISSIONAL_SUS", cbo: "CO_CBO", left_on: "DT_DESLIGAMENTO" }.freeze
    UNIT_BOND = { unit_id: "CO_UNIDADE", professional_id: "CO_PROFISSIONAL_SUS", cbo: "CO_CBO" }.freeze
    PROFESSIONAL = { professional_id: "CO_PROFISSIONAL_SUS", cpf: "CO_CPF", cns: "CO_CNS" }.freeze
  end
end
