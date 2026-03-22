# CClaude Agent - Android AI Agent with Full Undo Support

基于Zig语言编写的Android本地AI Agent，具备完整的撤销/重做功能。

## 核心特性

### 1. ReAct Agent 循环
- **推理(Reasoning)**: LLM分析用户需求
- **行动(Acting)**: 自动调用工具完成任务
- **观察(Observation)**: 分析工具执行结果
- **循环**: 直到任务完成

### 2. 8个核心工具 (全部支持撤销)

| 工具 | 风险等级 | 撤销支持 | 功能 |
|------|---------|---------|------|
| readfile | Safe | ❌ | 读取文件内容 |
| writefile | Moderate | ✅ | 写入文件（自动快照） |
| editfile | Moderate | ✅ | 查找替换（自动快照） |
| search | Safe | ❌ | 递归搜索文件 |
| glob | Safe | ❌ | 文件名模式匹配 |
| fetch | Safe | ❌ | HTTP请求 |
| web_search | Safe | ❌ | DuckDuckGo搜索 |
| shell | Dangerous | ❌ | 执行shell命令 |

### 3. 记忆系统 (Markdown上下文文件)

**上下文文件结构**:
```
data_dir/context/
├── SOUL.md      # Agent人格定义
├── USER.md      # 用户画像
├── MEMORY.md    # 项目知识
└── BOOTSTRAP.md # 首次启动引导
```

**版本控制特性**:
- 每次修改自动创建版本
- 支持回退到任意历史版本
- 类似git的commit历史

### 4. 撤销/重做系统 (核心设计原则)

**设计理念**: 所有操作都可以以无损或最小损失的方式回退

**支持的撤销操作**:
- ✅ 文件写入/编辑 (通过快照恢复)
- ✅ 记忆文件修改 (版本控制)
- ✅ 整个对话回合 (批量撤销)
- ✅ 工具调用链 (逐步撤销)

**API**:
```zig
// 撤销单个操作
agent.undo()

// 重做
agent.redo()

// 回滚整个对话
agent.rollbackConversation()

// 检查状态
agent.canUndo()
agent.canRedo()
agent.getUndoDescription()
```

### 5. AutoResearchClaw 科研功能

**23阶段研究管道**:
1. Idea Input
2. Literature Discovery (arXiv, Semantic Scholar)
3. Citation Validation (DOI cross-check)
4. Hypothesis Generation (多智能体辩论)
5. Experiment Design
6. Code Generation
7. Experiment Execution (沙箱)
8. Result Analysis
9. Hypothesis Validation (反馈循环)
10. Paper Writing (LaTeX)
11. Paper Formatting (ICML格式)

**特性**:
- 如果实验结果不支持假设，自动回滚到假设生成阶段
- 30天时间衰减的记忆模型 (MetaClaw)
- 自动学习失败教训并避免

## 项目结构

```
cclaude-agent/
├── zig-core/              # Zig核心库
│   ├── src/
│   │   ├── agent/         # ReAct Agent核心
│   │   ├── tools/         # 8个核心工具
│   │   ├── memory/        # Markdown记忆系统 + 版本控制
│   │   ├── research/      # AutoResearchClaw
│   │   ├── undo/          # 撤销/重做系统 ⭐核心
│   │   ├── utils/         # 工具函数
│   │   └── jni/           # JNI绑定
│   └── build.zig
│
└── android-app/           # Android应用
    ├── app/               # 主应用模块
    │   └── src/main/
    │       ├── java/com/cclaude/
    │       │   ├── ui/pages/      # ChatPage等
    │       │   ├── ui/components/ # ChatInput, ChatMessage
    │       │   └── service/       # ChatViewModel
    │       └── cpp/               # JNI C++ wrapper
    │
    └── zig-bridge/        # Zig-Kotlin桥接
        └── src/main/
            ├── java/com/cclaude/zig/
            │   ├── CClaudeNative.kt   # JNI声明
            │   └── CClaudeAgent.kt    # 高级封装
            └── cpp/
                └── cclaude_jni.cpp    # JNI实现
```

## 构建说明

### 1. 构建Zig核心库

```bash
cd zig-core

# 为Android ARM64构建
zig build -Dtarget=aarch64-linux-android

# 复制到Android项目
mkdir -p ../android-app/zig-bridge/src/main/jniLibs/arm64-v8a
cp zig-out/lib/libcclaude.so ../android-app/zig-bridge/src/main/jniLibs/arm64-v8a/
```

### 2. 构建Android应用

```bash
cd android-app
./gradlew assembleDebug
```

## 使用示例

### Kotlin代码

```kotlin
val agent = CClaudeAgent(context)

// 初始化
agent.initialize(apiKey = "your-api-key")

// 发送消息
agent.sendMessage("帮我创建一个Python项目") { token ->
    // 流式输出
    print(token)
}

// 撤销操作
if (agent.canUndo.value) {
    agent.undo()
}

// 重做
if (agent.canRedo.value) {
    agent.redo()
}

// 回滚整个对话
agent.rollbackConversation()
```

### Zig核心代码

```zig
var agent = try Agent.init(allocator, config);
defer agent.deinit();

// 发送消息
const response = try agent.send("Hello");

// 撤销
_ = try agent.undo();

// 重做
_ = try agent.redo();
```

## 撤销系统架构

### 快照系统 (Snapshot)

```zig
pub const Snapshot = struct {
    snapshot_type: SnapshotType,  // file_content, memory_section, etc.
    target_path: []const u8,
    data: []const u8,             // 序列化状态
    timestamp: i64,
};
```

### 操作日志 (Operation)

```zig
pub const Operation = struct {
    operation_type: OperationType,
    pre_snapshot: ?Snapshot,   // 操作前状态
    post_snapshot: ?Snapshot,  // 操作后状态（用于redo）
    tool_name: ?[]const u8,
    tool_args: ?[]const u8,
};
```

### 历史管理器 (UndoManager)

```zig
pub const UndoManager = struct {
    undo_stack: std.ArrayList(Operation),
    redo_stack: std.ArrayList(Operation),
    
    pub fn undo(self: *UndoManager) !?Operation
    pub fn redo(self: *UndoManager) !?Operation
    pub fn record(self: *UndoManager, operation: Operation) !void
};
```

## 设计理念

### 为什么需要完整的撤销支持？

1. **安全性**: AI Agent可能执行危险操作，用户需要后悔药
2. **实验性**: 用户可以放心尝试不同指令
3. **可调试**: 开发者和用户可以追踪问题
4. **信任**: 完整的撤销机制增加用户信任

### 最小损失回退

- 文件操作: 通过快照100%恢复
- 记忆修改: 版本控制，可精确回退
- 网络请求: 无法撤销（但可记录日志）
- Shell命令: 标记为危险，需用户确认

## License

MIT License - 参见原项目 so-c-claude 和 AutoResearchClaw
