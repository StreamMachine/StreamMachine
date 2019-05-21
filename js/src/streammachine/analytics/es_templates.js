var CoreObj, _;

_ = require("underscore");

CoreObj = {
  type: {
    type: "keyword",
    index: "true"
  },
  time: {
    type: "date",
    format: "date_time",
    doc_values: true
  },
  stream: {
    type: "keyword",
    index: "true",
    doc_values: true
  },
  session_id: {
    type: "keyword",
    index: "true",
    doc_values: true
  },
  client: {
    type: "object",
    properties: {
      session_id: {
        type: "keyword",
        index: "true",
        doc_values: true
      },
      user_id: {
        type: "keyword",
        index: "true",
        doc_values: true
      },
      output: {
        type: "keyword",
        index: "true",
        doc_values: true
      },
      ip: {
        type: "keyword",
        index: "true",
        doc_values: true
      },
      ua: {
        type: "keyword",
        index: "true",
        doc_values: true
      },
      path: {
        type: "keyword",
        index: "true",
        doc_values: true
      }
    }
  }
};

module.exports = {
  sessions: {
    settings: {
      index: {
        number_of_shards: 3,
        number_of_replicas: 1
      }
    },
    mappings: {
      properties: _.extend({}, CoreObj, {
        duration: {
          type: "float"
        },
        kbytes: {
          type: "long"
        }
      })
    }
  },
  listens: {
    settings: {
      index: {
        number_of_shards: 3,
        number_of_replicas: 1
      }
    },
    mappings: {
      properties: _.extend({}, CoreObj, {
        name: {
          type: "text"
        },
        duration: {
          type: "float"
        },
        kbytes: {
          type: "long"
        },
        offsetSeconds: {
          type: "integer",
          doc_values: true
        },
        contentTime: {
          type: "date",
          format: "date_time",
          doc_values: true
        }
      })
    }
  }
};

//# sourceMappingURL=es_templates.js.map
