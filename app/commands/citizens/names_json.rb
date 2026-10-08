# Os nomes como o balcão os vê (contratos §2): se o completo existe e o de
# exibição — nunca os três valores para quem só faz balcão.
module Citizens
  module NamesJson
    module_function

    def call(citizen) = { full_name_set: citizen.full_name.present?, display_name: citizen.display_name }
  end
end
