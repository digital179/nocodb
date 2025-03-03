<script setup lang="ts">
import type { Ref } from 'vue'
import type { ListItem as AntListItem } from 'ant-design-vue'
import jsep from 'jsep'
import type { editor as MonacoEditor } from 'monaco-editor'
import { KeyCode, Position, Range, languages, editor as monacoEditor } from 'monaco-editor'

import {
  FormulaDataTypes,
  FormulaError,
  UITypes,
  getUITypesForFormulaDataType,
  isHiddenCol,
  isVirtualCol,
  jsepCurlyHook,
  substituteColumnIdWithAliasInFormula,
  validateFormulaAndExtractTreeWithType,
} from 'nocodb-sdk'
import type { ColumnType, FormulaType } from 'nocodb-sdk'
import formulaLanguage from '../../monaco/formula'

const props = defineProps<{
  value: any
}>()
const emit = defineEmits(['update:value'])

const uiTypesNotSupportedInFormulas = [UITypes.QrCode, UITypes.Barcode]

const vModel = useVModel(props, 'value', emit)

const { setAdditionalValidations, sqlUi, column, validateInfos, fromTableExplorer } = useColumnCreateStoreOrThrow()

const { t } = useI18n()

const { predictFunction: _predictFunction } = useNocoEe()

const meta = inject(MetaInj, ref())

const { base: activeBase } = storeToRefs(useBase())

const supportedColumns = computed(
  () =>
    meta?.value?.columns?.filter((col) => {
      if (uiTypesNotSupportedInFormulas.includes(col.uidt as UITypes)) {
        return false
      }

      if (isHiddenCol(col, meta.value)) {
        return false
      }

      return true
    }) || [],
)
const { getMeta } = useMetas()

const suggestionPreviewed = ref<Record<any, string> | undefined>()

// If -1 Show Fields first, if 1 show Formulas first
const priority = ref(0)

const showFunctionList = ref<boolean>(true)

const validators = {
  formula_raw: [
    {
      validator: (_: any, formula: any) => {
        return (async () => {
          if (!formula?.trim()) throw new Error('Required')

          try {
            await validateFormulaAndExtractTreeWithType({
              column: column.value,
              formula,
              columns: supportedColumns.value,
              clientOrSqlUi: sqlUi.value,
              getMeta,
            })
          } catch (e: any) {
            if (e instanceof FormulaError && e.extra?.key) {
              throw new Error(t(e.extra.key, e.extra))
            }

            throw new Error(e.message)
          }
        })()
      },
    },
  ],
}

const availableFunctions = formulaList

const availableBinOps = ['+', '-', '*', '/', '>', '<', '==', '<=', '>=', '!=', '&']

const autocomplete = ref(false)

const variableListRef = ref<(typeof AntListItem)[]>([])

const sugOptionsRef = ref<(typeof AntListItem)[]>([])

const wordToComplete = ref<string | undefined>('')

const selected = ref(0)

const sortOrder: Record<string, number> = {
  column: 0,
  function: 1,
  op: 2,
}

const suggestionsList = computed(() => {
  const unsupportedFnList = sqlUi.value.getUnsupportedFnList()
  return (
    [
      ...availableFunctions.map((fn: string) => ({
        text: `${fn}()`,
        type: 'function',
        description: formulas[fn].description,
        syntax: formulas[fn].syntax,
        examples: formulas[fn].examples,
        docsUrl: formulas[fn].docsUrl,
        unsupported: unsupportedFnList.includes(fn),
      })),
      ...supportedColumns.value
        .filter((c) => {
          // skip system LTAR columns
          if (c.uidt === UITypes.LinkToAnotherRecord && c.system) return false
          // v1 logic? skip the current column
          if (!column) return true
          return column.value?.id !== c.id
        })
        .map((c: any) => ({
          text: c.title,
          type: 'column',
          icon: getUIDTIcon(c.uidt) ? markRaw(getUIDTIcon(c.uidt)!) : undefined,
          uidt: c.uidt,
        })),
      ...availableBinOps.map((op: string) => ({
        text: op,
        type: 'op',
      })),
    ]
      // move unsupported functions to the end
      .sort((a: Record<string, any>, b: Record<string, any>) => {
        if (a.unsupported && !b.unsupported) {
          return 1
        }
        if (!a.unsupported && b.unsupported) {
          return -1
        }
        return 0
      })
  )
})

// set default suggestion list
const suggestion: Ref<Record<string, any>[]> = ref(suggestionsList.value)

const acTree = computed(() => {
  const ref = new NcAutocompleteTree()
  for (const sug of suggestionsList.value) {
    ref.add(sug)
  }
  return ref
})

const suggestedFormulas = computed(() => {
  return suggestion.value.filter((s) => s && s.type !== 'column')
})

const variableList = computed(() => {
  return suggestion.value.filter((s) => s && s.type === 'column')
})

const monacoRoot = ref<HTMLDivElement>()
let editor: MonacoEditor.IStandaloneCodeEditor

function getCurrentKeyword() {
  const model = editor.getModel()
  const position = editor.getPosition()
  if (!model || !position) {
    return null
  }

  const word = model.getWordAtPosition(position)

  return word?.word
}

const handleInputDeb = useDebounceFn(function () {
  handleInput()
}, 250)

onMounted(async () => {
  if (monacoRoot.value) {
    const model = monacoEditor.createModel(vModel.value.formula_raw, 'formula')

    languages.register({
      id: formulaLanguage.name,
    })

    monacoEditor.defineTheme(formulaLanguage.name, formulaLanguage.theme)

    languages.setMonarchTokensProvider(
      formulaLanguage.name,
      formulaLanguage.generateLanguageDefinition(supportedColumns.value.map((c) => c.title!)),
    )

    languages.setLanguageConfiguration(formulaLanguage.name, formulaLanguage.languageConfiguration)

    monacoEditor.addKeybindingRules([
      {
        keybinding: KeyCode.DownArrow,
        when: 'editorTextFocus',
      },
      {
        keybinding: KeyCode.UpArrow,
        when: 'editorTextFocus',
      },
    ])

    editor = monacoEditor.create(monacoRoot.value, {
      model,
      'contextmenu': false,
      'theme': 'formula',
      'selectOnLineNumbers': false,
      'language': 'formula',
      'roundedSelection': false,
      'scrollBeyondLastLine': false,
      'lineNumbers': 'off',
      'glyphMargin': false,
      'folding': false,
      'wordWrap': 'on',
      'wrappingStrategy': 'advanced',
      // This seems to be a bug in the monoco.
      // https://github.com/microsoft/monaco-editor/issues/4535#issuecomment-2234042290
      'bracketPairColorization.enabled': false,
      'padding': {
        top: 8,
        bottom: 8,
      },
      'lineDecorationsWidth': 8,
      'lineNumbersMinChars': 0,
      'renderLineHighlight': 'none',
      'renderIndentGuides': false,
      'scrollbar': {
        horizontal: 'hidden',
      },
      'tabSize': 2,
      'automaticLayout': false,
      'overviewRulerLanes': 0,
      'hideCursorInOverviewRuler': true,
      'overviewRulerBorder': false,
      'matchBrackets': 'never',
      'minimap': {
        enabled: false,
      },
    })

    editor.layout({
      width: 339,
      height: 120,
    })

    editor.onDidChangeModelContent(async () => {
      vModel.value.formula_raw = editor.getValue()
      await handleInputDeb()
    })

    editor.onDidChangeCursorPosition(() => {
      const position = editor.getPosition()
      const model = editor.getModel()

      if (!position || !model) return

      const text = model.getValue()
      const offset = model.getOffsetAt(position)

      // IF cursor is inside string, don't show any suggestions
      if (isCursorInsideString(text, offset)) {
        autocomplete.value = false
        suggestion.value = []
      } else {
        handleInput()
      }

      const findEnclosingFunction = (text: string, offset: number) => {
        const formulaRegex = /\b(?<!['"])(\w+)\s*\(/g // Regular expression to match function names
        const quoteRegex = /"/g // Regular expression to match quotes

        const functionStack = [] // Stack to keep track of functions
        let inQuote = false

        let match
        while ((match = formulaRegex.exec(text)) !== null) {
          if (match.index > offset) break

          if (!inQuote) {
            const functionData = {
              name: match[1],
              start: match.index,
              end: formulaRegex.lastIndex,
            }

            let parenBalance = 1
            let childValueStart = -1
            let childValueEnd = -1
            for (let i = formulaRegex.lastIndex; i < text.length; i++) {
              if (text[i] === '(') {
                parenBalance++
              } else if (text[i] === ')') {
                parenBalance--
                if (parenBalance === 0) {
                  functionData.end = i + 1
                  break
                }
              }

              // Child value handling
              if (childValueStart === -1 && ['(', ',', '{'].includes(text[i])) {
                childValueStart = i
              } else if (childValueStart !== -1 && ['(', ',', '{'].includes(text[i])) {
                childValueStart = i
              } else if (childValueStart !== -1 && ['}', ',', ')'].includes(text[i])) {
                childValueEnd = i
                childValueStart = -1
              }

              if (i >= offset) {
                // If we've reached the offset and parentheses are still open, consider the current position as the end of the function
                if (parenBalance > 0) {
                  functionData.end = i + 1
                  break
                }

                // Check for nested functions
                const nestedFunction = findEnclosingFunction(
                  text.substring(functionData.start + match[1].length + 1, i),
                  offset - functionData.start - match[1].length - 1,
                )
                if (nestedFunction) {
                  return nestedFunction
                } else {
                  functionStack.push(functionData)
                  break
                }
              }
            }

            // If child value ended before offset, use child value end as function end
            if (childValueEnd !== -1 && childValueEnd < offset) {
              functionData.end = childValueEnd + 1
            }

            functionStack.push(functionData)
          }

          // Check for quotes
          let quoteMatch
          while ((quoteMatch = quoteRegex.exec(text)) !== null && quoteMatch.index < match.index) {
            inQuote = !inQuote
          }
        }

        const enclosingFunctions = functionStack.filter((func) => func.start <= offset && func.end >= offset)
        return enclosingFunctions.length > 0 ? enclosingFunctions[enclosingFunctions.length - 1].name : null
      }
      const lastFunction = findEnclosingFunction(text, offset)

      suggestionPreviewed.value =
        (suggestionsList.value.find((s) => s.text === `${lastFunction}()`) as Record<any, string>) || undefined
    })
    editor.focus()
  }
})

useResizeObserver(monacoRoot, (entries) => {
  const entry = entries[0]
  const { height } = entry.contentRect
  editor.layout({
    width: 339,
    height,
  })
})

function insertStringAtPosition(editor: MonacoEditor.IStandaloneCodeEditor, text: string, skipCursorMove = false) {
  const position = editor.getPosition()

  if (!position) {
    return
  }
  const range = new Range(position.lineNumber, position.column, position.lineNumber, position.column)

  editor.executeEdits('', [
    {
      range,
      text,
      forceMoveMarkers: true,
    },
  ])

  // Move the cursor to the end of the inserted text
  if (!skipCursorMove) {
    const newPosition = new Position(position.lineNumber, position.column + text.length - 1)
    editor.setPosition(newPosition)
  }

  editor.focus()
}

function appendText(item: Record<string, any>) {
  const len = wordToComplete.value?.length || 0

  if (!item?.text) return
  const text = item.text

  const position = editor.getPosition()

  if (!position) {
    return // No cursor position available
  }

  const newColumn = Math.max(1, position.column - len)

  const range = new Range(position.lineNumber, newColumn, position.lineNumber, position.column)

  editor.executeEdits('', [
    {
      range,
      text: '',
      forceMoveMarkers: true,
    },
  ])

  if (item.type === 'function') {
    insertStringAtPosition(editor, text)
  } else if (item.type === 'column') {
    insertStringAtPosition(editor, `{${text}}`, true)
  } else {
    insertStringAtPosition(editor, text, true)
  }
  autocomplete.value = false
  wordToComplete.value = ''

  if (item.type === 'function' || item.type === 'op') {
    // if function / operator is chosen, display columns only
    suggestion.value = suggestionsList.value.filter((f) => f.type === 'column')
  } else {
    // show all options if column is chosen
    suggestion.value = suggestionsList.value
  }
}

function isCursorBetweenParenthesis() {
  const cursorPosition = editor?.getPosition()

  if (!cursorPosition || !editor) return false

  const line = editor.getModel()?.getLineContent(cursorPosition.lineNumber)

  if (!line) {
    return false
  }

  const cursorLine = line.substring(0, cursorPosition.column - 1)

  const openParenthesis = (cursorLine.match(/\(/g) || []).length

  const closeParenthesis = (cursorLine.match(/\)/g) || []).length

  return openParenthesis > closeParenthesis
}

// Function to check if cursor is inside Strings
function isCursorInsideString(text: string, offset: number) {
  let inSingleQuoteString = false
  let inDoubleQuoteString = false
  let escapeNextChar = false

  for (let i = 0; i < offset; i++) {
    const char = text[i]

    if (escapeNextChar) {
      escapeNextChar = false
      continue
    }

    if (char === '\\') {
      escapeNextChar = true
      continue
    }

    if (char === "'" && !inDoubleQuoteString) {
      inSingleQuoteString = !inSingleQuoteString
    } else if (char === '"' && !inSingleQuoteString) {
      inDoubleQuoteString = !inDoubleQuoteString
    }
  }

  return inDoubleQuoteString || inSingleQuoteString
}

function handleInput() {
  if (!editor) return

  const model = editor.getModel()
  const position = editor.getPosition()

  if (!model || !position) return

  const text = model.getValue()
  const offset = model.getOffsetAt(position)

  // IF cursor is inside string, don't show any suggestions
  if (isCursorInsideString(text, offset)) {
    autocomplete.value = false
    suggestion.value = []
    return
  }

  if (!isCursorBetweenParenthesis()) priority.value = 1

  selected.value = 0
  suggestion.value = []
  const query = getCurrentKeyword() ?? ''
  const parts = query.split(/\W+/)
  wordToComplete.value = parts.pop() || ''
  suggestion.value = acTree.value
    .complete(wordToComplete.value)
    ?.sort((x: Record<string, any>, y: Record<string, any>) => sortOrder[x.type] - sortOrder[y.type])

  if (isCursorBetweenParenthesis()) {
    // Show columns at top
    suggestion.value = suggestion.value.sort((a, b) => {
      if (a.type === 'column') return -1
      if (b.type === 'column') return 1
      return 0
    })
    selected.value = 0
    priority.value = -1
  } else if (!showFunctionList.value) {
    showFunctionList.value = true
  }

  autocomplete.value = !!suggestion.value.length
}

function selectText() {
  if (suggestion.value && selected.value > -1 && selected.value < suggestionsList.value.length) {
    if (selected.value < suggestedFormulas.value.length) {
      if (suggestedFormulas.value[selected.value].unsupported) return
      appendText(suggestedFormulas.value[selected.value])
    } else {
      appendText(variableList.value[selected.value + suggestedFormulas.value.length])
    }
  }

  selected.value = 0
}

function suggestionListUp() {
  if (suggestion.value) {
    selected.value = --selected.value > -1 ? selected.value : suggestion.value.length - 1
    suggestionPreviewed.value = suggestedFormulas.value[selected.value]
    scrollToSelectedOption()
  }
}

function suggestionListDown() {
  if (suggestion.value) {
    selected.value = ++selected.value % suggestion.value.length
    suggestionPreviewed.value = suggestedFormulas.value[selected.value]

    scrollToSelectedOption()
  }
}

function scrollToSelectedOption() {
  nextTick(() => {
    if (sugOptionsRef.value[selected.value]) {
      try {
        sugOptionsRef.value[selected.value].$el.scrollIntoView({
          block: 'nearest',
          inline: 'start',
        })
      } catch (e) {}
    }
  })
}

// set default value
if ((column.value?.colOptions as any)?.formula_raw) {
  vModel.value.formula_raw =
    substituteColumnIdWithAliasInFormula(
      (column.value?.colOptions as FormulaType)?.formula,
      meta?.value?.columns as ColumnType[],
      (column.value?.colOptions as any)?.formula_raw,
    ) || ''
}

const source = computed(() => activeBase.value?.sources?.find((s) => s.id === meta.value?.source_id))

const parsedTree = computedAsync(async () => {
  try {
    const parsed = await validateFormulaAndExtractTreeWithType({
      formula: vModel.value.formula || vModel.value.formula_raw,
      columns: meta.value?.columns || [],
      column: column.value ?? undefined,
      clientOrSqlUi: source.value?.type as any,
      getMeta: async (modelId) => await getMeta(modelId),
    })
    return parsed
  } catch (e) {
    return {
      dataType: FormulaDataTypes.UNKNOWN,
    }
  }
})

// set additional validations
setAdditionalValidations({
  ...validators,
})

onMounted(() => {
  jsep.plugins.register(jsepCurlyHook)
})

const suggestionPreviewPostion = ref({
  top: '0px',
  left: '344px',
})

onMounted(() => {
  until(() => monacoRoot.value as HTMLDivElement)
    .toBeTruthy()
    .then(() => {
      setTimeout(() => {
        const monacoDivPosition = monacoRoot.value?.getBoundingClientRect()
        if (!monacoDivPosition) return

        suggestionPreviewPostion.value.top = `${monacoDivPosition.top}px`

        if (fromTableExplorer?.value || monacoDivPosition.left > 352) {
          suggestionPreviewPostion.value.left = `${monacoDivPosition.left - 344}px`
        } else {
          suggestionPreviewPostion.value.left = `${monacoDivPosition.right + 8}px`
        }
      }, 250)
    })
})

const handleKeydown = (e: KeyboardEvent) => {
  e.stopPropagation()
  switch (e.key) {
    case 'ArrowUp': {
      e.preventDefault()
      suggestionListUp()
      break
    }
    case 'ArrowDown': {
      e.preventDefault()
      suggestionListDown()
      break
    }
    case 'Enter': {
      e.preventDefault()
      selectText()
      break
    }
  }
}

const activeKey = ref('formula')

const supportedFormulaAlias = computed(() => {
  if (!parsedTree.value?.dataType) return []
  try {
    return getUITypesForFormulaDataType(parsedTree.value?.dataType as FormulaDataTypes).map((uidt) => {
      return {
        value: uidt,
        label: t(`datatype.${uidt}`),
        icon: h(
          isVirtualCol(uidt) ? resolveComponent('SmartsheetHeaderVirtualCellIcon') : resolveComponent('SmartsheetHeaderCellIcon'),
          {
            columnMeta: {
              uidt,
            },
          },
        ),
      }
    })
  } catch (e) {
    return []
  }
})

watch(
  () => vModel.value.meta?.display_type,
  (value, oldValue) => {
    if (oldValue === undefined && !value) {
      vModel.value.meta.display_column_meta = {
        meta: {},
        custom: {},
      }
    }
  },
  {
    immediate: true,
  },
)

watch(parsedTree, (value, oldValue) => {
  if (oldValue === undefined && value) {
    return
  }
  if (value?.dataType !== oldValue?.dataType) {
    vModel.value.meta.display_type = null
  }
})
</script>

<template>
  <div class="formula-wrapper relative">
    <div
      v-if="
        suggestionPreviewed &&
        !suggestionPreviewed.unsupported &&
        suggestionPreviewed.type === 'function' &&
        activeKey === 'formula'
      "
      class="w-84 fixed bg-white z-10 pl-3 pt-3 border-1 shadow-md rounded-xl"
      :style="{
        left: suggestionPreviewPostion.left,
        top: suggestionPreviewPostion.top,
      }"
    >
      <div class="pr-3">
        <div class="flex flex-row w-full justify-between pb-2 border-b-1">
          <div class="flex items-center gap-x-1 font-semibold text-lg text-gray-600">
            <component :is="iconMap.function" class="text-lg" />
            {{ suggestionPreviewed.text }}
          </div>
          <NcButton type="text" size="small" class="!h-7 !w-7 !min-w-0" @click="suggestionPreviewed = undefined">
            <GeneralIcon icon="close" />
          </NcButton>
        </div>
      </div>
      <div class="flex flex-col max-h-120 nc-scrollbar-thin pr-2">
        <div class="flex mt-3 text-[13px] leading-6">{{ suggestionPreviewed.description }}</div>

        <div class="text-gray-500 uppercase text-[11px] mt-3 mb-2">Syntax</div>
        <div class="bg-white rounded-md py-1 text-[13px] mono-font leading-6 px-2 border-1">{{ suggestionPreviewed.syntax }}</div>
        <div class="text-gray-500 uppercase text-[11px] mt-3 mb-2">Examples</div>
        <div
          v-for="(example, index) of suggestionPreviewed.examples"
          :key="example"
          class="bg-gray-100 mono-font text-[13px] leading-6 py-1 px-2"
          :class="{
            'border-t-1  border-gray-200': index !== 0,
            'rounded-b-md': index === suggestionPreviewed.examples.length - 1 && suggestionPreviewed.examples.length !== 1,
            'rounded-t-md': index === 0 && suggestionPreviewed.examples.length !== 1,
            'rounded-md': suggestionPreviewed.examples.length === 1,
          }"
        >
          {{ example }}
        </div>
      </div>
      <div class="flex flex-row mt-3 mb-3 justify-end pr-3">
        <a v-if="suggestionPreviewed.docsUrl" target="_blank" rel="noopener noreferrer" :href="suggestionPreviewed.docsUrl">
          <NcButton type="text" size="small" class="!text-gray-400 !hover:text-gray-700 !text-xs"
            >View in Docs
            <GeneralIcon icon="openInNew" class="ml-1" />
          </NcButton>
        </a>
      </div>
    </div>

    <NcTabs v-model:activeKey="activeKey">
      <a-tab-pane key="formula">
        <template #tab>
          <div class="tab">
            <div>{{ $t('datatype.Formula') }}</div>
          </div>
        </template>
        <div class="px-0.5">
          <a-form-item class="mt-4" v-bind="validateInfos.formula_raw">
            <div
              ref="monacoRoot"
              :class="{
                '!border-red-500 formula-error': validateInfos.formula_raw?.validateStatus === 'error',
                '!focus-within:border-brand-500 formula-success': validateInfos.formula_raw?.validateStatus !== 'error',
              }"
              class="formula-monaco"
              @keydown.stop="handleKeydown"
            ></div>
          </a-form-item>
          <div class="h-[250px] overflow-auto flex flex-col nc-scrollbar-thin border-1 border-gray-200 rounded-lg mt-4">
            <div v-if="suggestedFormulas && showFunctionList" :style="{ order: priority === -1 ? 2 : 1 }">
              <div class="border-b-1 bg-gray-50 px-3 py-1 uppercase text-gray-600 text-xs font-semibold sticky top-0 z-10">
                Formulas
              </div>

              <a-list :data-source="suggestedFormulas" :locale="{ emptyText: $t('msg.formula.noSuggestedFormulaFound') }">
                <template #renderItem="{ item, index }">
                  <a-list-item
                    :ref="
                      (el) => {
                        sugOptionsRef[index] = el
                      }
                    "
                    class="cursor-pointer !overflow-hidden hover:bg-gray-50"
                    :class="{
                      '!bg-gray-100': selected === index,
                      'cursor-not-allowed': item.unsupported,
                    }"
                    @click.prevent.stop="!item.unsupported && appendText(item)"
                    @mouseenter="suggestionPreviewed = item"
                  >
                    <a-list-item-meta>
                      <template #title>
                        <div class="flex items-center gap-x-1" :class="{ 'text-gray-400': item.unsupported }">
                          <component :is="iconMap.function" v-if="item.type === 'function'" class="w-4 h-4 !text-gray-600" />

                          <component :is="iconMap.calculator" v-if="item.type === 'op'" class="w-4 h-4 !text-gray-600" />

                          <component :is="item.icon" v-if="item.type === 'column'" class="w-4 h-4 !text-gray-600" />
                          <span class="text-small leading-[18px]" :class="{ 'text-gray-800': !item.unsupported }">{{
                            item.text
                          }}</span>
                        </div>
                        <div v-if="item.unsupported" class="ml-5 text-gray-400 text-xs">{{ $t('msg.formulaNotSupported') }}</div>
                      </template>
                    </a-list-item-meta>
                  </a-list-item>
                </template>
              </a-list>
            </div>

            <div v-if="variableList" :style="{ order: priority === 1 ? 2 : 1 }">
              <div class="border-b-1 bg-gray-50 px-3 py-1 uppercase text-gray-600 text-xs font-semibold sticky top-0 z-10">
                Fields
              </div>

              <a-list
                ref="variableListRef"
                :data-source="variableList"
                :locale="{ emptyText: $t('msg.formula.noSuggestedFieldFound') }"
                class="!overflow-hidden"
              >
                <template #renderItem="{ item, index }">
                  <a-list-item
                    :ref="
                      (el) => {
                        sugOptionsRef[index + suggestedFormulas.length] = el
                      }
                    "
                    :class="{
                      '!bg-gray-100': selected === index + suggestedFormulas.length,
                    }"
                    class="cursor-pointer hover:bg-gray-50"
                    @click.prevent.stop="appendText(item)"
                  >
                    <a-list-item-meta class="nc-variable-list-item">
                      <template #title>
                        <div class="flex items-center gap-x-1 justify-between">
                          <div class="flex items-center gap-x-1 rounded-md px-1 h-5">
                            <component :is="item.icon" class="w-4 h-4 !text-gray-600" />

                            <span class="text-small leading-[18px] text-gray-800 font-weight-500">{{ item.text }}</span>
                          </div>

                          <NcButton
                            size="small"
                            type="text"
                            class="nc-variable-list-item-use-field-btn !h-7 px-3 !text-small invisible"
                          >
                            {{ $t('general.use') }} {{ $t('objects.field').toLowerCase() }}
                          </NcButton>
                        </div>
                      </template>
                    </a-list-item-meta>
                  </a-list-item>
                </template>
              </a-list>
            </div>
          </div>
        </div>
      </a-tab-pane>

      <a-tab-pane key="format" :disabled="!supportedFormulaAlias?.length || !parsedTree?.dataType">
        <template #tab>
          <div class="tab">
            <div>{{ $t('labels.formatting') }}</div>
          </div>
        </template>
        <div class="flex flex-col px-0.5 gap-4">
          <a-form-item class="mt-4" :label="$t('general.format')">
            <a-select v-model:value="vModel.meta.display_type" class="w-full" :placeholder="$t('labels.selectAFormatType')">
              <a-select-option v-for="option in supportedFormulaAlias" :key="option.value" :value="option.value">
                <div class="flex w-full items-center gap-2 justify-between">
                  <div class="w-full">
                    <component :is="option.icon" class="w-4 h-4 !text-gray-600" />
                    {{ option.label }}
                  </div>
                  <component
                    :is="iconMap.check"
                    v-if="option.value === vModel.meta?.display_type"
                    id="nc-selected-item-icon"
                    class="text-primary w-4 h-4"
                  />
                </div>
              </a-select-option>
            </a-select>
          </a-form-item>

          <template
            v-if="
              [
                FormulaDataTypes.NUMERIC,
                FormulaDataTypes.DATE,
                FormulaDataTypes.BOOLEAN,
                FormulaDataTypes.STRING,
                FormulaDataTypes.COND_EXP,
              ].includes(parsedTree?.dataType)
            "
          >
            <SmartsheetColumnCurrencyOptions
              v-if="vModel.meta.display_type === UITypes.Currency"
              :value="vModel.meta.display_column_meta"
            />
            <SmartsheetColumnDecimalOptions
              v-else-if="vModel.meta.display_type === UITypes.Decimal"
              :value="vModel.meta.display_column_meta"
            />
            <SmartsheetColumnPercentOptions
              v-else-if="vModel.meta.display_type === UITypes.Percent"
              :value="vModel.meta.display_column_meta"
            />
            <SmartsheetColumnRatingOptions
              v-else-if="vModel.meta.display_type === UITypes.Rating"
              :value="vModel.meta.display_column_meta"
            />
            <SmartsheetColumnTimeOptions
              v-else-if="vModel.meta.display_type === UITypes.Time"
              :value="vModel.meta.display_column_meta"
            />
            <SmartsheetColumnDateTimeOptions
              v-else-if="vModel.meta.display_type === UITypes.DateTime"
              :value="vModel.meta.display_column_meta"
            />
            <SmartsheetColumnDateOptions
              v-else-if="vModel.meta.display_type === UITypes.Date"
              :value="vModel.meta.display_column_meta"
            />
            <SmartsheetColumnCheckboxOptions
              v-else-if="vModel.meta.display_type === UITypes.Checkbox"
              :value="vModel.meta.display_column_meta"
            />
          </template>
        </div>
      </a-tab-pane>
    </NcTabs>
  </div>
</template>

<style lang="scss" scoped>
:deep(.ant-list-item) {
  @apply !py-0 !px-2;

  &:not(:has(.nc-variable-list-item)) {
    @apply !py-[7px] !px-2;
  }
  .nc-variable-list-item {
    @apply min-h-8 flex items-center;
  }
  .ant-list-item-meta-title {
    @apply m-0;
  }
  &.ant-list-item,
  &.ant-list-item:last-child {
    @apply !border-b-1 border-gray-200 border-solid;
  }
  &:hover .nc-variable-list-item-use-field-btn {
    @apply visible;
  }
}

:deep(.ant-tabs-nav-wrap) {
  @apply !pl-0;
}

:deep(.ant-form-item-control-input) {
  @apply h-full;
}

:deep(.ant-tabs-content-holder) {
  @apply mt-4;
}

:deep(.ant-tabs-tab) {
  @apply !pb-0 pt-1;
}

:deep(.ant-tabs-nav) {
  @apply !mb-0 !pl-0;
}

:deep(.ant-tabs-tab-btn) {
  @apply !mb-1;
}

.formula-monaco {
  @apply rounded-md nc-scrollbar-md border-gray-200 border-1 overflow-y-auto overflow-x-hidden resize-y;
  min-height: 100px;
  height: 120px;
  max-height: 250px;

  &:focus-within:not(.formula-error) {
    box-shadow: 0 0 0 2px var(--ant-primary-color-outline);
  }

  &:focus-within:not(.formula-success) {
    box-shadow: 0 0 0 2px var(--ant-error-color-outline);
  }
  .view-line {
    width: auto !important;
  }
}

.mono-font {
  font-family: 'JetBrainsMono', monospace;
}
</style>
