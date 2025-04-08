const fs = require("fs");

// 从文件读取内容
function readFileAndTransform(filePath) {
  fs.readFile(filePath, "utf-8", (err, data) => {
    if (err) {
      console.error("读取文件时出错:", err);
      return;
    }
    const result = transformInput(data);
    console.log(result);
  });
}

// 转换函数
function transformInput(input) {
  // 匹配 Dart 类及其成员变量
  const classRegex = /class\s+(\w+)\s*{([^}]*)}/g;
  let classMatch;
  const output = [];

  while ((classMatch = classRegex.exec(input)) !== null) {
    const className = classMatch[1];
    const classBody = classMatch[2];

    // 提取类定义中的变量，使用正则表达式捕获成员变量
    // const variableRegex =
    //   /(int\s*\?\s*\w+;|int\s+\w+;|double\s*\?\s*\w+;|double\s+\w+;|String\s*\?\s*\w+;|String\s+\w+;|Null\s*\?\s*\w+;|Null\s+\w+;|List<\w+>\s*\?\s*\w+;|List<\w+>\s+\w+;|dynamic\s*\?\s*\w+;|dynamic\s+\w+;|bool\s*\?\s*\w+;|bool\s+\w+;)/g;
    const variableRegex =
      /(\w+\s*\?\s*\w+;|\w+\s+\w+;|List<\w+>\s*\?\s*\w+;|List<\w+>\s+\w+;)/g;

    const variables = classBody.match(variableRegex) || [];

    // 生成类的 fromJson 方法输出字符串
    const classOutput = [
      `\n\n\n----------------------------${className}----------------------------`,
      `\n${className}.fromJson(Map<String, dynamic> json) {`,
    ];

    const continueType = ["return"];

    for (let variable of variables) {
      const match = variable.match(/(\w+)(?:<([^>]+)>)?\s*\??\s*(\w+)/);
      if (match) {
        const varType = match[1]; // 基本类型
        const innerType = match[2] || ""; // 内嵌类型
        const varName = match[3]; // 变量名
        /// 判断类型后面是否有?,有则isNullable = true,否则为false
        const isNullable = variable.includes("?");

        if (continueType.includes(varType)) continue;

        // console.log(
        //   "varType:" +
        //     varType +
        //     ", innerType:" +
        //     innerType +
        //     ",varName:" +
        //     varName +
        //     ", isNullable:" +
        //     isNullable
        // );

        const defaultValue =
          {
            String: '""',
            int: "0",
            double: "0.0",
            bool: "false",
            List: "[]",
          }[varType] || `${varType}()`;

        const append = isNullable == true ? "" : ` ?? ${defaultValue}`;

        // 根据类型生成不同的解析语句
        switch (varType) {
          case "String":
          case "int":
          case "double":
          case "bool":
            classOutput.push(
              `    ${varName} = xbParse<${varType}>(json['${varName}'])${append};`
            );
            break;
          case "dynamic":
          case "Null":
            classOutput.push(`    ${varName} = json['${varName}'];`);
            break;
          case "List":
            {
              switch (innerType) {
                case "String":
                case "int":
                case "double":
                case "bool":
                case "Null":
                  classOutput.push(
                    `    ${varName} = xbParseList<${innerType}>(json['${varName}'])${append};`
                  );
                  break;
                default:
                  classOutput.push(
                    `    ${varName} = xbParseList(json['${varName}'], factory: ${innerType}.fromJson)${append};`
                  );
                  break;
              }
            }
            break;
          default:
            classOutput.push(
              `    ${varName} = xbParse(json['${varName}'], factory: ${varType}.fromJson)${append};`
            );
            break;
        }
      }
    }

    classOutput.push("}");

    // 生成类的 toJson 方法输出字符串
    const toJsonOutput = [
      `\nMap<String, dynamic> toJson() {`,
      `    final Map<String, dynamic> retMap = {};`,
    ];

    for (let variable of variables) {
      const match = variable.match(/(\w+)(?:<([^>]+)>)?\s*\??\s*(\w+)/);
      if (match) {
        const varType = match[1]; // 基本类型
        const innerType = match[2] || ""; // 内嵌类型
        const varName = match[3]; // 变量名

        if (continueType.includes(varType)) continue;

        if (varType === "List") {
          if (
            innerType === "bool" ||
            innerType === "int" ||
            innerType === "double" ||
            innerType === "String" ||
            innerType === "Null"
          ) {
            toJsonOutput.push(`    retMap['${varName}'] = ${varName};`);
          } else {
            toJsonOutput.push(`    if (${varName} != null) {`);
            toJsonOutput.push(
              `        retMap['${varName}'] = ${varName}!.map((v) => v.toJson()).toList();`
            );
            toJsonOutput.push(`    }`);
          }
        } else if (
          varType === "dynamic" ||
          varType === "bool" ||
          varType === "int" ||
          varType === "double" ||
          varType === "String" ||
          varType === "Null"
        ) {
          toJsonOutput.push(`    retMap['${varName}'] = ${varName};`);
        } else {
          toJsonOutput.push(`    retMap['${varName}'] = ${varName}?.toJson();`);
        }
      }
    }

    toJsonOutput.push(`    return retMap;`);
    toJsonOutput.push(`}\n`);

    output.push(classOutput.join("\n"));
    output.push(toJsonOutput.join("\n"));
  }

  return output.join("\n");
}

// 从命令行参数获取文件路径
const filePath = process.argv[2]; // 获取第二个参数
if (!filePath) {
  console.error("请提供文件路径作为参数");
  process.exit(1);
}

readFileAndTransform(filePath);
