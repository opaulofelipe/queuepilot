QueuePilot

QueuePilot é um motor de priorização de tickets desenvolvido em Ruby on Rails.

O objetivo do projeto é resolver um problema comum em equipes de suporte, atendimento e operações:

Quando existem muitos tickets abertos ao mesmo tempo, qual deve ser atendido primeiro?

Em muitos sistemas, a prioridade é definida apenas como baixa, média, alta ou urgente. O QueuePilot utiliza vários fatores para calcular uma prioridade dinâmica.

Como funciona

Cada ticket recebe uma pontuação entre 0 e 100.

O cálculo considera informações como:

* proximidade do vencimento do SLA;
* impacto do problema;
* urgência;
* quantidade de usuários afetados;
* tempo em que o ticket está aberto;
* tempo sem atendimento;
* quantidade de reaberturas;
* cliente estratégico;
* incidentes semelhantes;
* impacto em produção;
* sobrecarga do responsável.

A pontuação é transformada em uma prioridade:

90–100  → Critical
70–89   → High
45–69   → Medium
0–44    → Low

Exemplo

Um ticket pode retornar:

{
  ticket_id: 9381,
  score: 94.5,
  priority: :critical,
  risk: :high,
  confidence: :high
}

Além da prioridade, o sistema informa os motivos:

- SLA próximo do vencimento
- Alto impacto operacional
- Muitos usuários afetados
- Responsável atual sobrecarregado

Isso torna a decisão mais fácil de entender e auditar.

Distribuição de trabalho

O QueuePilot também pode verificar se o responsável atual está sobrecarregado.

Caso esteja, o sistema procura outro profissional considerando:

* quantidade de tickets ativos;
* carga estimada de trabalho;
* disponibilidade;
* habilidades necessárias para resolver o ticket.

Assim, o sistema não recomenda simplesmente a pessoa com menos tickets, mas alguém que também possua conhecimento adequado para aquele problema.

Proteção contra tickets esquecidos

Tickets de baixa prioridade podem acabar ficando indefinidamente no final da fila.

Para evitar isso, o QueuePilot aumenta gradualmente a pontuação de tickets muito antigos.

Essa estratégia ajuda a impedir que solicitações menos urgentes sejam esquecidas.

SLA

O tempo restante do SLA possui grande peso na priorização.

Um ticket de prioridade média próximo de ultrapassar o prazo pode passar à frente de um ticket novo classificado como alta prioridade.

Isso permite que a fila se adapte conforme o tempo passa.

Auditoria

Quando a opção de persistência está habilitada, o sistema pode registrar:

* score anterior;
* novo score;
* prioridade anterior;
* nova prioridade;
* motivos da alteração;
* responsável recomendado;
* componentes utilizados no cálculo.

Isso permite verificar posteriormente por que determinada decisão foi tomada.

Tecnologias e conceitos

O projeto demonstra conhecimentos em:

* Ruby;
* Ruby on Rails;
* ActiveRecord;
* Service Objects;
* orientação a objetos;
* regras de negócio;
* transações;
* processamento em lote;
* tratamento de erros;
* auditoria;
* observabilidade;
* algoritmos de priorização;
* balanceamento de carga.

Estrutura

O projeto foi propositalmente criado como um exemplo isolado de lógica de negócio.

queue-pilot/
│
├── app/
│   └── services/
│       └── queue_pilot/
│           └── ticket_prioritizer.rb
│
└── README.md

Não é uma aplicação completa.

O objetivo é demonstrar uma solução para um problema real de mercado utilizando Ruby on Rails.

Possíveis evoluções

O projeto poderia futuramente receber:

* dashboard de tickets;
* API REST;
* Sidekiq;
* Redis;
* integração com Jira;
* integração com Zendesk;
* integração com Slack;
* alertas de SLA;
* atualização em tempo real;
* métricas de desempenho da equipe.

Objetivo do projeto

O QueuePilot tenta responder quatro perguntas:

Qual ticket deve ser atendido primeiro?
Por que ele deve ser atendido primeiro?
Quem possui melhores condições para atendê-lo?
Qual é o risco de deixar esse ticket esperando?

O foco do projeto é demonstrar como Ruby on Rails pode ser utilizado para resolver uma regra de negócio mais complexa do que um CRUD tradicional.
