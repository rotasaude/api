require "rails_helper"

# A tela de manutenção (GET /manutencao) existe SÓ em development, e a garantia
# é o roteador, não um before_action: o bloco em config/routes.rb está dentro de
# um `if Rails.env.development?`, então fora de dev a rota não é desenhada e o
# Rails responde 404 na camada de roteamento.
#
# Por que assim: a tela lê a configuração de todas as cidades sem autenticar
# ninguém. Uma rota que EXISTE e nega está a uma linha de distância de uma rota
# que existe e aceita — um `skip_before_action` mal colocado, um refactor de
# herança, um controller pai trocado. Uma rota que não existe não tem esse
# caminho.
#
# Este spec roda em test, onde Rails.env.development? é false. Ele prova a
# ausência, que é a metade verificável — a presença em dev é exercitada à mão,
# abrindo a página. A outra metade (o conteúdo) é coberta por
# spec/services/city_inventory_spec.rb, que não depende de rota nenhuma.
#
# A prova é no ROTEADOR, não por requisição: `recognize_path` pergunta ao
# RouteSet se algum desenho casa com o caminho, que é exatamente o invariante.
# Uma segunda checagem via `get` provaria o mesmo fato por um caminho mais
# frágil — e nesta suíte `infer_spec_type_from_file_location!` está desligado,
# então `get` nem existe fora de um grupo marcado `type: :request`.
RSpec.describe "the maintenance screen is development-only" do
  it "does not exist outside development" do
    expect(Rails.env.development?).to be(false)

    expect { Rails.application.routes.recognize_path("/manutencao") }
      .to raise_error(ActionController::RoutingError)
  end
end
