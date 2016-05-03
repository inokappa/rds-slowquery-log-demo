# RDS のスロークエリを出来るだけ手軽に可視化する考察

![](http://cdn-ak.f.st-hatena.com/images/fotolife/i/inokara/20160503/20160503145236.png)

## モチベーション

- RDS のスロークエリをお手軽に可視化出来ないものか
- 実サービスへの影響を極力抑える
- 可視化する手間は極力省く

ということで、docker-compose を利用することで、ほぼコマンド一発で可視化する環境は起動するはず。

***

## 参考

- http://qiita.com/ryonext/items/e8491f8abd360fae4095
- http://kikumoto.hatenablog.com/entry/2015/12/04/000152#in_mysqlslowquery_ex

***

## 使い方

### RDS のパラメータグループの設定

- log_output : TABLE
- slow_query_log : 1
- long_query_time : 任意の秒数

### fluent.conf を設定する

```
<source>
  @type rds_slowlog
  tag rds-slowlog
  host ${RDS_ENDPOINT}
  username ${RDS_USERNAME}
  password ${RDS_PASSWORD}
</source>

(snip)

```

### コンテナのビルドと起動

コンテナをビルドして起動する。

```sh
docker-compose build
docker-compose up -d
```

### mapping template を指定する

mapping template を指定する。

```javascript
curl -XPUT http://elasticsearch:9200/_template/mysqlslowquery_template -d '
{
  "template": "mysqlslowquery-*",
  "mappings": {
    "mysqlslowquery": {
      "properties": {
        "query_time_float": { "type": "float" },
        "lock_time_float": { "type": "float" },
        "rows_examined": { "type": "integer" },
        "rows_sent": { "type": "integer" },
        "sql_text": {
          "type": "string",
          "fields": {
            "raw": {"type": "string", "index": "not_analyzed"}
          }
        }
      }
    }
  }
}'
```

mapping template を設定後、念のためにインデックスを削除しておく。

```sh
curl -XDELETE "elasticsearch:9200/mysqlslowquery-*"
```

### Kibana で確認

スロークエリが検出されると Elasticsearch にログが蓄積されるので、あとは Kibana で確認する。
Kibana テンプレートも一応用意してあるのでインポートすれば OK 牧場。

```sh
% tree kibana
kibana
├── dashiboard.json
├── discover.json
└── visualize.json

0 directories, 3 files
```

***

## 面倒だったところ

- 当初は TABLE では無く、FILE で記録したかったけど断念
- `sql_text` は analyze させないこと(`multi_field` は利用出来ないので注意する)
- ローテーションを行う際のクエリも飛んできてしまうので fluent-plugin-rewrite でローテーションクエリを除外
- `query_time` と `lock_time` のフォーマットが `NN:NN:NN` となっているので record_transformer プラグインで強引に数値化している

***

## todo

- スロークエリログを FILE にした場合にどのように可視化するかを検討する
- docker-compose v2 に対応させる
