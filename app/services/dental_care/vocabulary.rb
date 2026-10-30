# Vocabulário fixo da consulta odontológica para GET
# /attendance/consultation_options (ADR 0046; contrato §16 O4, O20, O25):
# cada item { code, label } com o código em string. Sem dado pessoal; vai
# sempre, mesmo com o interruptor desligado (a consulta retida segue legível).
# Rótulos da FAO conferidos em vendor/ledi/8.7.0/docs/dicionario.html
# (TipoDeAtendimento, TipoDeConsultaOdonto, VigilanciaEmSaudeBucal,
# FornecimentoOdonto, CondutaEncaminhamentoOdonto); os códigos são os do
# DentalCare::Catalog.
module DentalCare
  module Vocabulary
    CARE_TYPES = { 2 => "Consulta agendada", 4 => "Escuta inicial / Orientação", 5 => "Consulta no dia",
                   6 => "Atendimento de urgência" }.freeze
    CONSULTATION_TYPES = { 1 => "Primeira consulta odontológica programática", 2 => "Consulta de retorno em odontologia",
                           4 => "Consulta de manutenção em odontologia" }.freeze
    SURVEILLANCE = { 1 => "Abscesso dento alveolar", 2 => "Alteração em tecidos moles", 3 => "Dor de dente",
                     4 => "Fendas / Fissuras lábio palatais", 5 => "Fluorose dentária moderada / severa",
                     6 => "Traumatismo dento alveolar", 99 => "Não identificado" }.freeze
    SUPPLIES = { 1 => "Escova dental", 2 => "Creme dental", 3 => "Fio dental" }.freeze
    OUTCOMES = {
      1 => "Atendimento à pacientes com necessidades especiais", 2 => "Cirurgia BMF", 3 => "Endodontia", 4 => "Estomatologia",
      5 => "Implantodontia", 6 => "Odontopediatria", 7 => "Ortodontia / Ortopedia", 8 => "Periodontia", 9 => "Prótese dentária",
      10 => "Radiologia", 11 => "Outros", 12 => "Agendamento para outros profissionais AB", 14 => "Agendamento para grupos",
      15 => "Tratamento concluído", 16 => "Retorno para consulta agendada", 17 => "Alta do episódio", 18 => "Agendamento para eMulti"
    }.freeze

    module_function

    def options
      { care_types: coded(CARE_TYPES, Catalog::CARE_TYPES), consultation_types: coded(CONSULTATION_TYPES, Catalog::CONSULTATION_TYPES),
        surveillance: coded(SURVEILLANCE, Catalog::SURVEILLANCE), supplies: coded(SUPPLIES, Catalog::SUPPLIES),
        outcomes: coded(OUTCOMES, Catalog::OUTCOMES), situations: situations }
    end

    # Situações do odontograma (config/dental/situations.yml, Desvio 4): coroa,
    # raiz, arcada e as de coroa que valem na face.
    def situations
      %i[crown root arch face].index_with { |part| Situations.list(part).map { |s| { code: s[:code], label: s[:label] } } }
    end

    def coded(labels, codes) = codes.map { |code| { code: code.to_s, label: labels.fetch(code) } }
    private_class_method :coded
  end
end
